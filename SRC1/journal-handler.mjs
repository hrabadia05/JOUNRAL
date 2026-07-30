// journal-handler.mjs
// Handles: POST /journal (create entry + AI analysis), GET /journal (list entries), PUT /journal (update), DELETE /journal (delete)

import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, PutCommand, QueryCommand, UpdateCommand, DeleteCommand } from "@aws-sdk/lib-dynamodb";
import { S3Client, PutObjectCommand, GetObjectCommand } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import { BedrockRuntimeClient, InvokeModelCommand } from "@aws-sdk/client-bedrock-runtime";
import { GoogleGenAI } from "@google/genai";
import { randomUUID } from "crypto";

const REGION = process.env.AWS_REGION_NAME || process.env.AWS_REGION;
const JOURNAL_TABLE = process.env.JOURNAL_TABLE;
const BUCKET_NAME = process.env.BUCKET_NAME;
const GEMINI_API_KEY = process.env.GEMINI_API_KEY;
const GEMINI_MODEL_ID = process.env.GEMINI_MODEL_ID || "gemini-3.6-flash";
const BEDROCK_MODEL_ID = process.env.BEDROCK_MODEL_ID || "meta.llama3-2-11b-instruct-v1:0";

const ddbClient = new DynamoDBClient({ region: REGION });
const ddb = DynamoDBDocumentClient.from(ddbClient);
const s3 = new S3Client({ region: REGION });
const bedrock = new BedrockRuntimeClient({ region: REGION });

function respond(statusCode, body) {
  return {
    statusCode,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  };
}

function buildSortKey(date, entryId) {
  return `${date}#${entryId}`;
}

function getUserId(event) {
  const claims = event.requestContext?.authorizer?.jwt?.claims;
  if (!claims) return null;
  return claims.sub;
}

function calculatePnl(direction, entryPrice, exitPrice, quantity = 1, instrument = "") {
  if (entryPrice == null || exitPrice == null) return null;
  const entryP = parseFloat(entryPrice);
  const exitP = parseFloat(exitPrice);
  const qty = parseFloat(quantity) || 1;
  if (isNaN(entryP) || isNaN(exitP)) return null;

  const MULTIPLIERS = { ES: 50, NQ: 20, MES: 5, MNQ: 2 };
  const mult = MULTIPLIERS[(instrument || "").toUpperCase()] || 1;

  const points = direction === "Short" ? entryP - exitP : exitP - entryP;
  return points * mult * qty;
}

function buildAnalysisPrompt({ instrument, tradeDirection, entryPrice, exitPrice, notes }) {
  return [
    "You are a professional futures trading coach reviewing a trade journal entry.",
    `Instrument: ${instrument}`,
    `Direction: ${tradeDirection}`,
    `Entry Price: ${entryPrice ?? "N/A"}`,
    `Exit Price: ${exitPrice ?? "N/A"}`,
    `Trader's Notes: ${notes || "(none provided)"}`,
    "",
    "Analyze the trade using the attached chart screenshot if present. Respond ONLY with strict JSON",
    'in the shape: {"summary": string, "strengths": string[], "mistakes": string[], "riskManagementScore": number (1-10), "suggestion": string}',
  ].join("\n");
}

async function analyzeWithGemini(prompt, imageBase64) {
  if (!GEMINI_API_KEY) throw new Error("GEMINI_API_KEY not configured");

  const ai = new GoogleGenAI({ apiKey: GEMINI_API_KEY });

  const parts = [{ text: prompt }];
  if (imageBase64) {
    parts.push({
      inlineData: {
        mimeType: "image/png",
        data: imageBase64,
      },
    });
  }

  const response = await ai.models.generateContent({
    model: GEMINI_MODEL_ID,
    contents: [{ role: "user", parts }],
  });

  const text = response.text ?? response.candidates?.[0]?.content?.parts?.[0]?.text;
  if (!text) throw new Error("Empty response from Gemini");
  return parseAiJson(text);
}

async function analyzeWithBedrock(prompt, imageBase64) {
  const payload = {
    prompt,
    max_gen_len: 800,
    temperature: 0.4,
    ...(imageBase64 ? { images: [imageBase64] } : {}),
  };

  const command = new InvokeModelCommand({
    modelId: BEDROCK_MODEL_ID,
    contentType: "application/json",
    accept: "application/json",
    body: JSON.stringify(payload),
  });

  const result = await bedrock.send(command);
  const raw = new TextDecoder().decode(result.body);
  const parsed = JSON.parse(raw);
  const text = parsed.generation || parsed.completion || parsed.outputText;
  if (!text) throw new Error("Empty response from Bedrock");
  return parseAiJson(text);
}

function parseAiJson(text) {
  const cleaned = text.replace(/```json/gi, "").replace(/```/g, "").trim();
  try {
    return JSON.parse(cleaned);
  } catch {
    return {
      summary: cleaned.slice(0, 1000),
      strengths: [],
      mistakes: [],
      riskManagementScore: null,
      suggestion: "AI response could not be parsed as structured JSON.",
    };
  }
}

async function runAiAnalysis(fields, imageBase64) {
  const prompt = buildAnalysisPrompt(fields);
  try {
    const analysis = await analyzeWithGemini(prompt, imageBase64);
    return { source: "gemini", ...analysis };
  } catch (err) {
    console.warn("Gemini analysis failed, falling back to Bedrock:", err?.message);
    try {
      const analysis = await analyzeWithBedrock(prompt, imageBase64);
      return { source: "bedrock-fallback", ...analysis };
    } catch (fallbackErr) {
      console.error("Bedrock fallback also failed:", fallbackErr?.message);
      return {
        source: "unavailable",
        summary: "AI analysis is temporarily unavailable. Your trade was still saved.",
        strengths: [],
        mistakes: [],
        riskManagementScore: null,
        suggestion: null,
      };
    }
  }
}

async function handlePost(event, userId) {
  let body;
  try {
    const raw = event.isBase64Encoded ? Buffer.from(event.body, "base64").toString("utf-8") : event.body;
    body = JSON.parse(raw || "{}");
  } catch {
    return respond(400, { error: "Invalid JSON body" });
  }

  const { date, instrument, quantity, notes, tradeDirection, entryPrice, exitPrice, imageBase64 } = body;

  if (!date || !instrument || !tradeDirection) {
    return respond(400, { error: "date, instrument, and tradeDirection are required" });
  }

  const ALLOWED_INSTRUMENTS = ["ES", "NQ", "MES", "MNQ"];
  if (!ALLOWED_INSTRUMENTS.includes(instrument)) {
    return respond(400, { error: `instrument must be one of ${ALLOWED_INSTRUMENTS.join(", ")}` });
  }

  let chartImageKey = null;
  let cleanImageBase64 = null;

  if (imageBase64) {
    cleanImageBase64 = imageBase64.includes(",") ? imageBase64.split(",")[1] : imageBase64;
    const buffer = Buffer.from(cleanImageBase64, "base64");
    chartImageKey = `${userId}/${randomUUID()}.png`;

    await s3.send(
      new PutObjectCommand({
        Bucket: BUCKET_NAME,
        Key: chartImageKey,
        Body: buffer,
        ContentType: "image/png",
      })
    );
  }

  const aiAnalysis = await runAiAnalysis(
    { instrument, tradeDirection, entryPrice, exitPrice, notes },
    cleanImageBase64
  );

  const entryId = randomUUID();
  const sortKey = buildSortKey(date, entryId);
  const qty = parseFloat(quantity) || 1;
  const calculatedPnl = calculatePnl(tradeDirection, entryPrice, exitPrice, qty, instrument);

  const item = {
    UserId: userId,
    SortKey: sortKey,
    EntryDate: date,
    EntryId: entryId,
    Instrument: instrument,
    Quantity: qty,
    TradeDirection: tradeDirection,
    EntryPrice: entryPrice ?? null,
    ExitPrice: exitPrice ?? null,
    Pnl: calculatedPnl,
    Notes: notes || "",
    ChartImageKey: chartImageKey,
    AiAnalysis: aiAnalysis,
    CreatedAt: Date.now(),
  };

  await ddb.send(new PutCommand({ TableName: JOURNAL_TABLE, Item: item }));

  let responseItem = {
    entryId: item.EntryId,
    date: item.EntryDate,
    instrument: item.Instrument,
    quantity: item.Quantity,
    direction: item.TradeDirection,
    entryPrice: item.EntryPrice,
    exitPrice: item.ExitPrice,
    pnl: item.Pnl,
    notes: item.Notes,
    aiAnalysis: item.AiAnalysis,
    createdAt: item.CreatedAt,
  };

  if (chartImageKey) {
    try {
      const url = await getSignedUrl(
        s3,
        new GetObjectCommand({ Bucket: BUCKET_NAME, Key: chartImageKey }),
        { expiresIn: 900 }
      );
      responseItem.chartImageUrl = url;
    } catch (err) {
      console.warn(`Failed to sign URL for new entry ${chartImageKey}:`, err?.message);
    }
  }

  return respond(201, responseItem);
}

async function handleGet(event, userId) {
  const result = await ddb.send(
    new QueryCommand({
      TableName: JOURNAL_TABLE,
      KeyConditionExpression: "UserId = :uid",
      ExpressionAttributeValues: { ":uid": userId },
      ScanIndexForward: false,
    })
  );

  const entries = result.Items || [];

  const formattedEntries = await Promise.all(
    entries.map(async (entry) => {
      let signedUrl = null;
      if (entry.ChartImageKey) {
        try {
          signedUrl = await getSignedUrl(
            s3,
            new GetObjectCommand({ Bucket: BUCKET_NAME, Key: entry.ChartImageKey }),
            { expiresIn: 900 }
          );
        } catch (err) {
          console.warn(`Failed to sign URL for ${entry.ChartImageKey}:`, err?.message);
        }
      }

      const qty = entry.Quantity ?? 1;
      return {
        entryId: entry.EntryId,
        date: entry.EntryDate,
        instrument: entry.Instrument,
        quantity: qty,
        direction: entry.TradeDirection,
        entryPrice: entry.EntryPrice,
        exitPrice: entry.ExitPrice,
        pnl: entry.Pnl ?? calculatePnl(entry.TradeDirection, entry.EntryPrice, entry.ExitPrice, qty, entry.Instrument),
        notes: entry.Notes,
        aiAnalysis: entry.AiAnalysis,
        chartImageUrl: signedUrl,
        createdAt: entry.CreatedAt,
      };
    })
  );

  return respond(200, { entries: formattedEntries });
}

async function handlePut(event, userId) {
  let body;
  try {
    const raw = event.isBase64Encoded ? Buffer.from(event.body, "base64").toString("utf-8") : event.body;
    body = JSON.parse(raw || "{}");
  } catch {
    return respond(400, { error: "Invalid JSON body" });
  }

  const { date, entryId, notes, tradeDirection, entryPrice, exitPrice, quantity, instrument } = body;
  if (!date || !entryId) {
    return respond(400, { error: "date and entryId are required to identify the entry being edited" });
  }

  const updateFields = {};
  if (notes !== undefined) updateFields.Notes = notes;
  if (tradeDirection !== undefined) updateFields.TradeDirection = tradeDirection;
  if (entryPrice !== undefined) updateFields.EntryPrice = entryPrice;
  if (exitPrice !== undefined) updateFields.ExitPrice = exitPrice;
  if (quantity !== undefined) updateFields.Quantity = parseFloat(quantity) || 1;

  if (entryPrice !== undefined || exitPrice !== undefined || tradeDirection !== undefined || quantity !== undefined) {
    const qty = quantity !== undefined ? parseFloat(quantity) : 1;
    updateFields.Pnl = calculatePnl(tradeDirection, entryPrice, exitPrice, qty, instrument);
  }

  if (Object.keys(updateFields).length === 0) {
    return respond(400, { error: "No editable fields provided" });
  }

  updateFields.UpdatedAt = Date.now();

  const updateExpressionParts = [];
  const expressionAttributeNames = {};
  const expressionAttributeValues = {};
  for (const [key, value] of Object.entries(updateFields)) {
    updateExpressionParts.push(`#${key} = :${key}`);
    expressionAttributeNames[`#${key}`] = key;
    expressionAttributeValues[`:${key}`] = value;
  }

  try {
    const result = await ddb.send(
      new UpdateCommand({
        TableName: JOURNAL_TABLE,
        Key: { UserId: userId, SortKey: buildSortKey(date, entryId) },
        UpdateExpression: `SET ${updateExpressionParts.join(", ")}`,
        ExpressionAttributeNames: expressionAttributeNames,
        ExpressionAttributeValues: expressionAttributeValues,
        ConditionExpression: "attribute_exists(SortKey)",
        ReturnValues: "ALL_NEW",
      })
    );

    let item = result.Attributes;
    let signedUrl = null;
    if (item?.ChartImageKey) {
      try {
        signedUrl = await getSignedUrl(
          s3,
          new GetObjectCommand({ Bucket: BUCKET_NAME, Key: item.ChartImageKey }),
          { expiresIn: 900 }
        );
      } catch (err) {
        console.warn("Failed to sign URL after update:", err?.message);
      }
    }

    return respond(200, {
      entryId: item.EntryId,
      date: item.EntryDate,
      instrument: item.Instrument,
      quantity: item.Quantity ?? 1,
      direction: item.TradeDirection,
      entryPrice: item.EntryPrice,
      exitPrice: item.ExitPrice,
      pnl: item.Pnl ?? calculatePnl(item.TradeDirection, item.EntryPrice, item.ExitPrice, item.Quantity, item.Instrument),
      notes: item.Notes,
      aiAnalysis: item.AiAnalysis,
      chartImageUrl: signedUrl,
      createdAt: item.CreatedAt,
    });
  } catch (err) {
    if (err.name === "ConditionalCheckFailedException") {
      return respond(404, { error: "Entry not found" });
    }
    throw err;
  }
}

async function handleDelete(event, userId) {
  let body;
  try {
    const raw = event.isBase64Encoded ? Buffer.from(event.body, "base64").toString("utf-8") : event.body;
    body = JSON.parse(raw || "{}");
  } catch {
    return respond(400, { error: "Invalid JSON body" });
  }

  const { date, entryId } = body;
  if (!date || !entryId) {
    return respond(400, { error: "date and entryId are required to identify the entry being deleted" });
  }

  try {
    await ddb.send(
      new DeleteCommand({
        TableName: JOURNAL_TABLE,
        Key: { UserId: userId, SortKey: buildSortKey(date, entryId) },
        ConditionExpression: "attribute_exists(SortKey)",
      })
    );
    return respond(200, { deleted: true, entryId });
  } catch (err) {
    if (err.name === "ConditionalCheckFailedException") {
      return respond(404, { error: "Entry not found" });
    }
    throw err;
  }
}

export const handler = async (event) => {
  const method = event.requestContext?.http?.method;

  if (method === "OPTIONS") {
    return { statusCode: 200, body: "" };
  }

  const userId = getUserId(event);
  if (!userId) {
    return respond(401, { error: "Unauthorized: missing Cognito JWT claims" });
  }

  try {
    if (method === "POST") return await handlePost(event, userId);
    if (method === "GET") return await handleGet(event, userId);
    if (method === "PUT") return await handlePut(event, userId);
    if (method === "DELETE") return await handleDelete(event, userId);
    return respond(405, { error: "Method not allowed" });
  } catch (err) {
    console.error("Unhandled error:", err);
    return respond(500, { error: "Internal server error" });
  }
};