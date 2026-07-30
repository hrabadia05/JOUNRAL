// chat-handler.mjs
// Handles WebSocket routes: $connect, $disconnect, sendMessage, getChatHistory

import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import {
  DynamoDBDocumentClient,
  PutCommand,
  DeleteCommand,
  ScanCommand,
  QueryCommand,
  GetCommand,
} from "@aws-sdk/lib-dynamodb";
import {
  ApiGatewayManagementApiClient,
  PostToConnectionCommand,
} from "@aws-sdk/client-apigatewaymanagementapi";
import { CognitoIdentityProviderClient, GetUserCommand } from "@aws-sdk/client-cognito-identity-provider";
import { randomUUID } from "crypto";

const REGION = process.env.AWS_REGION;
const CONNECTIONS_TABLE = process.env.CONNECTIONS_TABLE;
const MESSAGES_TABLE = process.env.MESSAGES_TABLE;
const ROOM_ID = "global";

const ddbClient = new DynamoDBClient({ region: REGION });
const ddb = DynamoDBDocumentClient.from(ddbClient);
const cognito = new CognitoIdentityProviderClient({ region: REGION });

function getManagementApiClient(event) {
  const domainName = event.requestContext.domainName;
  const stage = event.requestContext.stage;
  return new ApiGatewayManagementApiClient({
    region: REGION,
    endpoint: `https://${domainName}/${stage}`,
  });
}

async function postToConnection(apiClient, connectionId, payload) {
  try {
    await apiClient.send(
      new PostToConnectionCommand({
        ConnectionId: connectionId,
        Data: Buffer.from(JSON.stringify(payload)),
      })
    );
    return true;
  } catch (err) {
    if (err?.$metadata?.httpStatusCode === 410 || err?.name === "GoneException") {
      // Stale connection — clean it up.
      await ddb.send(new DeleteCommand({ TableName: CONNECTIONS_TABLE, Key: { ConnectionId: connectionId } }));
    } else {
      console.error(`Failed to post to connection ${connectionId}:`, err?.message);
    }
    return false;
  }
}

async function handleConnect(event) {
  const token = event.queryStringParameters?.token;
  if (!token) {
    return { statusCode: 401, body: "Missing auth token" };
  }

  try {
    const userResp = await cognito.send(new GetUserCommand({ AccessToken: token }));
    const email = userResp.UserAttributes?.find((a) => a.Name === "email")?.Value || userResp.Username;

    await ddb.send(
      new PutCommand({
        TableName: CONNECTIONS_TABLE,
        Item: {
          ConnectionId: event.requestContext.connectionId,
          UserId: userResp.Username,
          UserHandle: email,
          ConnectedAt: Date.now(),
        },
      })
    );

    return { statusCode: 200, body: "Connected" };
  } catch (err) {
    console.error("Cognito token validation failed:", err?.message);
    return { statusCode: 401, body: "Unauthorized" };
  }
}

async function handleDisconnect(event) {
  await ddb.send(
    new DeleteCommand({
      TableName: CONNECTIONS_TABLE,
      Key: { ConnectionId: event.requestContext.connectionId },
    })
  );
  return { statusCode: 200, body: "Disconnected" };
}

async function handleSendMessage(event) {
  const apiClient = getManagementApiClient(event);
  const connectionId = event.requestContext.connectionId;

  let body;
  try {
    body = JSON.parse(event.body || "{}");
  } catch {
    await postToConnection(apiClient, connectionId, { type: "error", error: "Invalid JSON" });
    return { statusCode: 200, body: "" };
  }

  const messageText = (body.message || "").toString().trim().slice(0, 2000);
  if (!messageText) {
    await postToConnection(apiClient, connectionId, { type: "error", error: "Message cannot be empty" });
    return { statusCode: 200, body: "" };
  }

  // Look up the sender's handle from their connection record.
  const senderRecord = await ddb.send(
    new GetCommand({ TableName: CONNECTIONS_TABLE, Key: { ConnectionId: connectionId } })
  );
  const userHandle = senderRecord.Item?.UserHandle || "Unknown";
  const userId = senderRecord.Item?.UserId || "unknown";

  const messageItem = {
    RoomId: ROOM_ID,
    Timestamp: Date.now(),
    MessageId: randomUUID(),
    UserId: userId,
    UserHandle: userHandle,
    Message: messageText,
  };

  await ddb.send(new PutCommand({ TableName: MESSAGES_TABLE, Item: messageItem }));

  // Broadcast to all active connections.
  const connectionsResult = await ddb.send(new ScanCommand({ TableName: CONNECTIONS_TABLE }));
  const connections = connectionsResult.Items || [];

  const payload = { type: "message", message: messageItem };

  await Promise.all(
    connections.map((conn) => postToConnection(apiClient, conn.ConnectionId, payload))
  );

  return { statusCode: 200, body: "" };
}

async function handleGetChatHistory(event) {
  const apiClient = getManagementApiClient(event);
  const connectionId = event.requestContext.connectionId;

  const result = await ddb.send(
    new QueryCommand({
      TableName: MESSAGES_TABLE,
      KeyConditionExpression: "RoomId = :room",
      ExpressionAttributeValues: { ":room": ROOM_ID },
      ScanIndexForward: false,
      Limit: 50,
    })
  );

  const history = (result.Items || []).reverse(); // chronological order for the client

  await postToConnection(apiClient, connectionId, { type: "history", messages: history });

  return { statusCode: 200, body: "" };
}

export const handler = async (event) => {
  const routeKey = event.requestContext?.routeKey;

  try {
    switch (routeKey) {
      case "$connect":
        return await handleConnect(event);
      case "$disconnect":
        return await handleDisconnect(event);
      case "sendMessage":
        return await handleSendMessage(event);
      case "getChatHistory":
        return await handleGetChatHistory(event);
      default:
        return { statusCode: 400, body: `Unknown route: ${routeKey}` };
    }
  } catch (err) {
    console.error("Unhandled chat-handler error:", err);
    return { statusCode: 500, body: "Internal server error" };
  }
};
