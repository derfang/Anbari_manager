import { onCall, HttpsError } from "firebase-functions/v2/https";
import * as admin from "firebase-admin";

admin.initializeApp();
const db = admin.firestore();

export const onChoreCompleted = onCall(async (request) => {
  // 1. Security Check: Ensure user is authenticated
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "User must be logged in.");
  }

  // 2. In v2, data is extracted from request.data
  const { roomId, choreId, doerIds } = request.data; 

  try {
    await db.runTransaction(async (transaction) => {
      // Read the chore data to get the effortValue
      const choreRef = db.collection("chores").doc(choreId);
      const choreDoc = await transaction.get(choreRef);
      if (!choreDoc.exists) throw new Error("Chore not found");
      const effortValue = choreDoc.data()?.effortValue;

      // Read all users in the room to find out who is present vs. absent
      const usersRef = db.collection("users").where("roomId", "==", roomId);
      const usersSnapshot = await transaction.get(usersRef);
      
      let presentSlackers: admin.firestore.QueryDocumentSnapshot[] = [];
      let doers: admin.firestore.QueryDocumentSnapshot[] = [];

      usersSnapshot.forEach((doc) => {
        const userData = doc.data();
        if (doerIds.includes(doc.id)) {
          doers.push(doc);
        } else if (!userData.isAbsent) {
          presentSlackers.push(doc);
        }
      });

      // Calculate the zero-sum point distribution
      const slackerTax = (effortValue * doers.length) / presentSlackers.length;

      // Apply the updates inside the transaction
      doers.forEach((doer) => {
        const newPoints = (doer.data().points || 0) + effortValue;
        transaction.update(doer.ref, { points: newPoints });
      });

      presentSlackers.forEach((slacker) => {
        const newPoints = (slacker.data().points || 0) - slackerTax;
        transaction.update(slacker.ref, { points: newPoints });
      });

      // Log the completion
      const historyRef = db.collection("chore_history").doc();
      transaction.set(historyRef, {
        roomId: roomId,
        choreId: choreId,
        completedBy: doerIds,
        completedAt: admin.firestore.FieldValue.serverTimestamp(),
        effortValue: effortValue
      });
    });

    return { success: true, message: "Zero-sum points distributed successfully." };

  } catch (error) {
    console.error("Transaction failed: ", error);
    throw new HttpsError("internal", "Math engine failed.");
  }
});