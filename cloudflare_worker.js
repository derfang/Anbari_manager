/**
 * Cloudflare Worker for sending Firebase Cloud Messaging (FCM) Push Notifications
 * AND running scheduled background tasks (Cron jobs).
 */

// Helper to construct a JWT signature
async function signJwt(header, payload, privateKey) {
  const enc = new TextEncoder();
  const stringifiedHeader = btoa(JSON.stringify(header)).replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
  const stringifiedPayload = btoa(JSON.stringify(payload)).replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
  const unsignedToken = `${stringifiedHeader}.${stringifiedPayload}`;

  const pemContents = privateKey
    .replace(/-----BEGIN PRIVATE KEY-----/g, '')
    .replace(/-----END PRIVATE KEY-----/g, '')
    .replace(/\\n/g, '')
    .replace(/\s/g, '');
  const binaryDerString = atob(pemContents);
  const binaryDer = new Uint8Array(binaryDerString.length);
  for (let i = 0; i < binaryDerString.length; i++) {
    binaryDer[i] = binaryDerString.charCodeAt(i);
  }

  const key = await crypto.subtle.importKey(
    "pkcs8",
    binaryDer.buffer,
    { name: "RSASSA-PKCS1-v1_5", hash: { name: "SHA-256" } },
    false,
    ["sign"]
  );

  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    enc.encode(unsignedToken)
  );

  const base64Signature = btoa(String.fromCharCode(...new Uint8Array(signature)))
    .replace(/=/g, '')
    .replace(/\+/g, '-')
    .replace(/\//g, '_');

  return `${unsignedToken}.${base64Signature}`;
}

// Helper to get Google OAuth token (Now includes Datastore scope for Firestore reads)
async function getAccessToken(serviceAccount) {
  const now = Math.floor(Date.now() / 1000);
  const payload = {
    iss: serviceAccount.client_email,
    scope: 'https://www.googleapis.com/auth/firebase.messaging https://www.googleapis.com/auth/datastore',
    aud: 'https://oauth2.googleapis.com/token',
    exp: now + 3600,
    iat: now
  };

  const header = { alg: 'RS256', typ: 'JWT' };
  const jwt = await signJwt(header, payload, serviceAccount.private_key);

  const response = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: `grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=${jwt}`
  });

  const data = await response.json();
  return data.access_token;
}

// Sends a single push notification via FCM
async function sendFCMMessage(projectId, accessToken, token, title, body) {
  const fcmPayload = {
    message: {
      token: token,
      notification: { title: title, body: body },
      android: { priority: 'high' },
      apns: { payload: { aps: { sound: 'default' } } }
    }
  };

  const response = await fetch(`https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`, {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${accessToken}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(fcmPayload)
  });
  
  return response.ok;
}

export default {
  // 1. Handles HTTP POST requests (Event-driven notifications from the app)
  async fetch(request, env, ctx) {
    // Handle CORS preflight requests
    if (request.method === 'OPTIONS') {
      return new Response(null, {
        headers: {
          'Access-Control-Allow-Origin': '*',
          'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
          'Access-Control-Allow-Headers': 'Content-Type',
        },
      });
    }

    if (request.method !== 'POST') {
      return new Response('Method not allowed', { 
        status: 405,
        headers: { 'Access-Control-Allow-Origin': '*' }
      });
    }

    try {
      const body = await request.json();
      const { token, title, body: messageBody } = body;

      if (!token || !title || !messageBody) {
        return new Response('Missing required fields', { 
          status: 400,
          headers: { 'Access-Control-Allow-Origin': '*' }
        });
      }

      const serviceAccountStr = env.SERVICE_ACCOUNT_JSON;
      if (!serviceAccountStr) return new Response('SERVICE_ACCOUNT_JSON missing', { 
        status: 500,
        headers: { 'Access-Control-Allow-Origin': '*' }
      });
      const serviceAccount = JSON.parse(serviceAccountStr);

      const accessToken = await getAccessToken(serviceAccount);
      const success = await sendFCMMessage(serviceAccount.project_id, accessToken, token, title, messageBody);

      return new Response(JSON.stringify({ success }), { 
        status: success ? 200 : 500,
        headers: {
          'Access-Control-Allow-Origin': '*',
          'Content-Type': 'application/json'
        }
      });
    } catch (e) {
      return new Response(JSON.stringify({ error: e.message }), { 
        status: 500,
        headers: {
          'Access-Control-Allow-Origin': '*',
          'Content-Type': 'application/json'
        }
      });
    }
  },

  // 2. Handles CRON Triggers (Scheduled 7PM check for incomplete chores)
  async scheduled(event, env, ctx) {
    try {
      console.log("Cron triggered! Checking for incomplete chores...");
      const serviceAccountStr = env.SERVICE_ACCOUNT_JSON;
      if (!serviceAccountStr) return;
      const serviceAccount = JSON.parse(serviceAccountStr);
      const projectId = serviceAccount.project_id;
      
      const accessToken = await getAccessToken(serviceAccount);

      // Get today's date string matching the format in Firestore (YYYY-MM-DD)
      const todayStr = new Date().toISOString().split('T')[0];

      // Query Firestore for all assignments where `day` == today AND `isCompleted` == false
      const queryPayload = {
        structuredQuery: {
          from: [{ collectionId: "assignments" }],
          where: {
            compositeFilter: {
              op: "AND",
              filters: [
                { fieldFilter: { field: { fieldPath: "day" }, op: "EQUAL", value: { stringValue: todayStr } } },
                { fieldFilter: { field: { fieldPath: "isCompleted" }, op: "EQUAL", value: { booleanValue: false } } }
              ]
            }
          }
        }
      };

      const queryRes = await fetch(`https://firestore.googleapis.com/v1/projects/${projectId}/databases/(default)/documents:runQuery`, {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${accessToken}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify(queryPayload)
      });

      const results = await queryRes.json();
      
      // If no results, Firestore returns an array with a single object containing no 'document' key.
      if (!results || !Array.isArray(results) || results.length === 0 || !results[0].document) {
        console.log("No incomplete chores today! Everyone is being good.");
        return;
      }

      // We group by userId so we only send 1 notification per user, even if they have 3 chores left.
      const slackerUsers = {}; 

      for (const res of results) {
        if (!res.document) continue;
        const fields = res.document.fields;
        const userId = fields.assignedToUserId?.stringValue;
        const choreTitle = fields.choreTitle?.stringValue;
        if (userId && choreTitle) {
          if (!slackerUsers[userId]) {
            slackerUsers[userId] = [];
          }
          slackerUsers[userId].push(choreTitle);
        }
      }

      // Now, lookup each user's FCM token and send them a push notification
      for (const [userId, chores] of Object.entries(slackerUsers)) {
        // Fetch the user's document
        const userRes = await fetch(`https://firestore.googleapis.com/v1/projects/${projectId}/databases/(default)/documents/users/${userId}`, {
          method: 'GET',
          headers: { 'Authorization': `Bearer ${accessToken}` }
        });

        const userData = await userRes.json();
        if (userData && userData.fields && userData.fields.fcmToken) {
          const fcmToken = userData.fields.fcmToken.stringValue;
          if (fcmToken) {
            const firstChore = chores[0];
            const title = "Chore Reminder 🚨";
            const body = chores.length > 1 
              ? `It's getting late and you still have ${chores.length} chores to do (like ${firstChore}). Don't forget!`
              : `It's getting late and '${firstChore}' isn't done... the trash bags are starting to form a union. 🗑️`;
            
            console.log(`Sending reminder to ${userId} for ${chores.length} chores.`);
            await sendFCMMessage(projectId, accessToken, fcmToken, title, body);
          }
        }
      }

    } catch (e) {
      console.error("Cron Job Error:", e);
    }
  }
};
