import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web3dart/crypto.dart';
import 'package:web3dart/web3dart.dart';
import 'package:xmtp_proto/xmtp_proto.dart' as xmtp;

import 'package:xmtp/src/common/api.dart';
import 'package:xmtp/src/common/signature.dart';
import 'package:xmtp/src/common/time64.dart';
import 'package:xmtp/src/common/topic.dart';
import 'package:xmtp/src/common/crypto.dart';
import 'package:xmtp/src/auth.dart';
import 'package:xmtp/src/contact.dart';
import 'package:xmtp/src/content/codec_registry.dart';
import 'package:xmtp/src/content/text_codec.dart';
import 'package:xmtp/src/conversation/conversation_v2.dart';

import '../test_server.dart';

void main() {
  // This creates 2 users connected to the API and sends DMs
  // back and forth using message API V2.
  test(
    skip: skipUnlessTestServerEnabled,
    "v2 messaging: invites, reading, writing, streaming",
    () async {
      var aliceWallet = EthPrivateKey.createRandom(Random.secure()).asSigner();
      var bobWallet = EthPrivateKey.createRandom(Random.secure()).asSigner();
      var charlieWallet =
          EthPrivateKey.createRandom(Random.secure()).asSigner();
      var alice = await _createLocalManager(aliceWallet);
      var bob = await _createLocalManager(bobWallet);
      var charlie = await _createLocalManager(charlieWallet);
      var aliceAddress = aliceWallet.address.hex;
      var bobAddress = bobWallet.address.hex;
      var charlieAddress = charlieWallet.address.hex;

      var aliceChats = await alice.listConversations();
      var bobChats = await bob.listConversations();
      var charlieChats = await charlie.listConversations();
      expect(aliceChats.length, 0);
      expect(bobChats.length, 0);
      expect(charlieChats.length, 0);

      // Alice initiates the conversation (sending off the invites)
      var aliceConvo = await alice.newConversation(
        bobAddress,
        xmtp.InvitationV1_Context(
          conversationId: "example.com/alice-and-bob",
          metadata: {"title": "Alice & Bob"},
        ),
      );
      await delayToPropagate();

      // They both get the invite.
      expect((await alice.listConversations()).length, 1);
      expect((await bob.listConversations()).length, 1);
      var bobConvo = (await bob.listConversations())[0];

      // They see each other as the recipients.
      expect(aliceConvo.peer, bobWallet.address);
      expect(bobConvo.peer, aliceWallet.address);

      // Alice initiates another conversation (sending off the invites)
      var charlieConvo = await alice.newConversation(
        charlieAddress,
        xmtp.InvitationV1_Context(
          conversationId: "example.com/alice-and-charlie",
          metadata: {"title": "Alice & Charlie"},
        ),
      );
      await delayToPropagate();

      // Bob starts listening to the stream and recording the transcript.
      var transcript = [];
      var bobListening = bob.streamMessages([bobConvo]).listen(
          (msg) => transcript.add('${msg.sender.hex}> ${msg.content}'));

      // Alice sends the first message.
      await alice.sendMessage(aliceConvo, "hello Bob, it's me Alice!");
      await delayToPropagate();

      // And Bob see the message in the conversation.
      var bobMessages = await bob.listMessages([bobConvo]);
      expect(bobMessages.length, 1);
      expect(bobMessages[0].sender, aliceWallet.address);
      expect(bobMessages[0].content, "hello Bob, it's me Alice!");

      // Bob replies
      await bob.sendMessage(bobConvo, "oh, hello Alice!");
      await delayToPropagate();

      var aliceMessages = await alice.listMessages([aliceConvo]);
      expect(aliceMessages.length, 2);
      expect(aliceMessages[0].sender, bobWallet.address);
      expect(aliceMessages[0].content, "oh, hello Alice!");
      expect(aliceMessages[1].sender, aliceWallet.address);
      expect(aliceMessages[1].content, "hello Bob, it's me Alice!");

      // Charlie sends a message to Alice
      await charlie.sendMessage(charlieConvo, "hey Alice, it's Charlie");
      await delayToPropagate();

      var bobAndCharlieMessages =
          await alice.listMessages([bobConvo, charlieConvo]);
      expect(bobAndCharlieMessages.length, 3);
      expect(bobAndCharlieMessages[0].sender, charlieWallet.address);
      expect(bobAndCharlieMessages[0].content, "hey Alice, it's Charlie");
      expect(bobAndCharlieMessages[1].sender, bobWallet.address);
      expect(bobAndCharlieMessages[1].content, "oh, hello Alice!");
      expect(bobAndCharlieMessages[2].sender, aliceWallet.address);
      expect(bobAndCharlieMessages[2].content, "hello Bob, it's me Alice!");

      await bobListening.cancel();
      expect(transcript, [
        "$aliceAddress> hello Bob, it's me Alice!",
        "$bobAddress> oh, hello Alice!",
      ]);
    },
  );

  // This creates 2 users having a conversation and prepares
  // an invalid message from the one pretending to be someone else
  // to verify that it is properly discarded.
  test(
    skip: skipUnlessTestServerEnabled,
    "v2 messaging: invalid sender key bundles on a message should be discarded",
    () async {
      var aliceWallet = EthPrivateKey.createRandom(Random.secure()).asSigner();
      var alice = await _createLocalManager(aliceWallet);
      var aliceAddress = aliceWallet.address.hexEip55;

      var bobWallet = EthPrivateKey.createRandom(Random.secure()).asSigner();
      var bob = await _createLocalManager(bobWallet);
      var bobAddress = bobWallet.address.hexEip55;

      // This is the fake user that Bob pretends to be.
      var carlWallet = EthPrivateKey.createRandom(Random.secure()).asSigner();
      var carlIdentity = EthPrivateKey.createRandom(Random.secure());
      var carlKeys = await carlWallet.createIdentity(carlIdentity);
      // Carl's contact bundle is publically available.
      var carlContact = createContactBundleV2(carlKeys);

      // Alice initiates the conversation (sending off the invites)
      var aliceConvo = await alice.newConversation(
          bobAddress,
          xmtp.InvitationV1_Context(
            conversationId: "example.com/sneaky-fake-sender-key-bundle",
          ));
      await delayToPropagate();
      var bobConvo = (await bob.listConversations())[0];

      // Helper to inspect transcript (from Alice's perspective).
      getTranscript() async => (await alice.listMessages([aliceConvo]))
          .reversed
          .map((msg) => '${msg.sender.hexEip55}> ${msg.content}');

      await alice.sendMessage(aliceConvo, "hello Bob, it's me Alice!");
      await delayToPropagate();
      await bob.sendMessage(bobConvo, "oh hi Alice, it's me Bob!");
      await delayToPropagate();

      // Everything looks good,
      expect(await getTranscript(), [
        "$aliceAddress> hello Bob, it's me Alice!",
        "$bobAddress> oh hi Alice, it's me Bob!",
      ]);

      // Now Bob tries to pretend to be Carl using Carl's contact info.
      var original = await TextCodec().encode("I love you!");
      var now = nowNs();
      var header = xmtp.MessageHeaderV2(topic: bobConvo.topic, createdNs: now);
      var signed = await signContent(bob.auth.keys, header, original);

      // Here's where Bob pretends to be Carl using Carl's public identity key.
      signed.sender.identityKey = carlContact.v2.keyBundle.identityKey;

      var fakeMessage = await encryptMessageV2(bobConvo.invite, header, signed);
      await bob.api.client.publish(xmtp.PublishRequest(envelopes: [
        xmtp.Envelope(
          contentTopic: bobConvo.topic,
          timestampNs: now,
          message: xmtp.Message(v2: fakeMessage).writeToBuffer(),
        )
      ]));
      await delayToPropagate();

      // ... then Alice can inspect the topic directly to see the bad message.
      var inspecting = await alice.api.client
          .query(xmtp.QueryRequest(contentTopics: [aliceConvo.topic]));
      expect(inspecting.envelopes.length, 3 /* = 2 valid + 1 bad */);

      // ... but when she lists messages the fake one is properly discarded.
      expect(await getTranscript(), [
        "$aliceAddress> hello Bob, it's me Alice!",
        "$bobAddress> oh hi Alice, it's me Bob!",
        // There's no fake message here from Carl
      ]);

      await alice.sendMessage(aliceConvo, "did you say something?");

      // ... and the conversation continues on, still discarding bad messages.
      expect(await getTranscript(), [
        "$aliceAddress> hello Bob, it's me Alice!",
        "$bobAddress> oh hi Alice, it's me Bob!",
        // There's no fake message here from Carl
        "$aliceAddress> did you say something?",
      ]);
    },
  );

  // This creates 2 users connected to the API and prepares
  // an invalid invitation (mismatched timestamps)
  // to verify that it is properly discarded.
  test(
    skip: skipUnlessTestServerEnabled,
    "v2 messaging: mismatched timestamps on an invite should be discarded",
    () async {
      var aliceWallet = EthPrivateKey.createRandom(Random.secure()).asSigner();
      var bobWallet = EthPrivateKey.createRandom(Random.secure()).asSigner();
      var alice = await _createLocalManager(aliceWallet);
      var bob = await _createLocalManager(bobWallet);
      var bobAddress = bobWallet.address.hex;

      var aliceChats = await alice.listConversations();
      var bobChats = await bob.listConversations();
      expect(aliceChats.length, 0);
      expect(bobChats.length, 0);

      // Use low-level API call to pretend Alice sent an invalid invitation.
      var badInviteSealedAt = nowNs();
      var badInvitePublishedAt = nowNs() + 12345;
      // Note: these ^ timestamps do not match which makes the envelope invalid
      var bobPeer = await alice.contacts.getUserContactV2(bobAddress);
      var invalidInvite = await encryptInviteV1(
        alice.auth.keys,
        bobPeer.v2.keyBundle,
        await createInviteV1(
            alice.auth.keys,
            bobPeer.v2.keyBundle,
            xmtp.InvitationV1_Context(
              conversationId: "example.com/not-valid-mismatched-timestamps",
            )),
        badInviteSealedAt,
      );
      await alice.api.client.publish(xmtp.PublishRequest(envelopes: [
        xmtp.Envelope(
          contentTopic: Topic.userInvite(bobAddress),
          timestampNs: badInvitePublishedAt,
          message: invalidInvite.writeToBuffer(),
        )
      ]));
      await delayToPropagate();

      // Now looking at the low-level invites we see that Bob has received it...
      var raw = await bob.api.client.query(xmtp.QueryRequest(
        contentTopics: [Topic.userInvite(bobAddress)],
      ));
      expect(
        xmtp.SealedInvitation.fromBuffer(raw.envelopes[0].message),
        invalidInvite,
      );
      // ... but when Bob lists conversations the invalid one is discarded.
      expect((await bob.listConversations()).length, 0);

      // But later if Alice sends a _valid_ invite...
      await alice.newConversation(
        bobAddress,
        xmtp.InvitationV1_Context(
          conversationId: "example.com/valid",
        ),
      );
      await delayToPropagate();

      // ... then Bob should see that new conversation (and still discard the
      // earlier invalid invitation).
      expect((await bob.listConversations()).length, 1);
      var bobConvo = (await bob.listConversations())[0];
      expect(bobConvo.conversationId, "example.com/valid");
    },
  );

  test(
    "v2 messaging: low-level deterministic invite creation",
    () async {
      var aliceWallet = EthPrivateKey.createRandom(Random.secure()).asSigner();
      var bobWallet = EthPrivateKey.createRandom(Random.secure()).asSigner();
      var aliceKeys = await aliceWallet.createIdentity(generateKeyPair());
      var bobKeys = await bobWallet.createIdentity(generateKeyPair());
      makeInvite(String conversationId) => createInviteV1(
            aliceKeys,
            createContactBundleV2(bobKeys).v2.keyBundle,
            xmtp.InvitationV1_Context(conversationId: conversationId),
          );

      // Repeatedly making the same invite should use the same topic/keys
      var original = await makeInvite("example.com/conversation-foo");
      for (var i = 0; i < 10; ++i) {
        var invite = await makeInvite("example.com/conversation-foo");
        expect(original.topic, invite.topic);
      }

      // But when the conversationId changes then it use a new topic/keys
      var invite = await makeInvite("example.com/conversation-bar");
      expect(original.topic, isNot(invite.topic));
    },
  );

  test(
    "v2 messaging: generates known deterministic topic",
    () async {
      var aliceKeys = xmtp.PrivateKeyBundle.fromBuffer(hexToBytes(
          // address = 0xF56d1F3b1290204441Cb3843C2Cac1C2f5AEd690
          "0x0a8a030ac20108c192a3f7923112220a2068d2eb2ef8c50c4916b42ce638c5610e44ff4eb3ecb098" +
              "c9dacf032625c72f101a940108c192a3f7923112460a440a40fc9822283078c323c9319c45e60ab4" +
              "2c65f6e1744ed8c23c52728d456d33422824c98d307e8b1c86a26826578523ba15fe6f04a17fca17" +
              "6664ee8017ec8ba59310011a430a410498dc2315dd45d99f5e900a071e7b56142de344540f07fbc7" +
              "3a0f9a5d5df6b52eb85db06a3825988ab5e04746bc221fcdf5310a44d9523009546d4bfbfbb89cfb" +
              "12c20108eb92a3f7923112220a20788be9da8e1a1a08b05f7cbf22d86980bc056b130c482fa5bd26" +
              "ccb8d29b30451a940108eb92a3f7923112460a440a40a7afa25cb6f3fbb98f9e5cd92a1df1898452" +
              "e0dfa1d7e5affe9eaf9b72dd14bc546d86c399768badf983f07fa7dd16eee8d793357ce6fccd6768" +
              "07d87bcc595510011a430a410422931e6295c3c93a5f6f5e729dc02e1754e916cb9be16d36dc163a" +
              "300931f42a0cd5fde957d75c2068e1980c5f86843daf16aba8ae57e8160b8b9f0191def09e"));
      var bobKeys = xmtp.PrivateKeyBundle.fromBuffer(hexToBytes(
          // address = 0x3De402A325323Bb97f00cE3ad5bFAc96A11F9A34
          "0x0a88030ac001088cd68df7923112220a209057f8d813314a2aae74e6c4c30f909c1c496b6037ce32" +
              "a12c613558a8e961681a9201088cd68df7923112440a420a40501ae9b4f75d5bb5bae3ca4ecfda4e" +
              "de9edc5a9b7fc2d56dc7325b837957c23235cc3005b46bb9ef485f106404dcf71247097ed5096355" +
              "90f4b7987b833d03661a430a4104e61a7ae511567f4a2b5551221024b6932d6cdb8ecf3876ec64cf" +
              "29be4291dd5428fc0301963cdf6939978846e2c35fd38fcb70c64296a929f166ef6e4e91045712c2" +
              "0108b8d68df7923112220a2027707399474d417bf6aae4baa3d73b285bf728353bc3e156b0e32461" +
              "ebb48f8c1a940108b8d68df7923112460a440a40fb96fa38c3f013830abb61cf6b39776e0475eb13" +
              "79c66013569c3d2daecdd48c7fbee945dcdbdc5717d1f4ffd342c4d3f1b7215912829751a94e3ae1" +
              "1007e0a110011a430a4104952b7158cfe819d92743a4132e2e3ae867d72f6a08292aebf471d0a7a2" +
              "907f3e9947719033e20edc9ca9665874bd88c64c6b62c01928065f6069c5c80c699924"));
      var aliceInvite = await createInviteV1(
        aliceKeys,
        createContactBundleV2(bobKeys).v2.keyBundle,
        xmtp.InvitationV1_Context(conversationId: "test"),
      );
      expect(
        aliceInvite.topic,
        "/xmtp/0/m-4b52be1e8567d72d0bc407debe2d3c7fca2ae93a47e58c3f9b5c5068aff80ec5/proto",
        reason: "it should produce the same topic as the JS SDK",
      );

      var bobInvite = await createInviteV1(
        bobKeys,
        createContactBundleV2(aliceKeys).v2.keyBundle,
        xmtp.InvitationV1_Context(conversationId: "test"),
      );
      expect(
        bobInvite.topic,
        "/xmtp/0/m-4b52be1e8567d72d0bc407debe2d3c7fca2ae93a47e58c3f9b5c5068aff80ec5/proto",
        reason: "it should produce the same topic as the JS SDK",
      );
    },
  );

  test(
    "v2 messaging: deterministic invite creation bidirectionally",
        () async {
      var aliceWallet = EthPrivateKey.createRandom(Random.secure()).asSigner();
      var bobWallet = EthPrivateKey.createRandom(Random.secure()).asSigner();
      var aliceKeys = await aliceWallet.createIdentity(generateKeyPair());
      var bobKeys = await bobWallet.createIdentity(generateKeyPair());
      var bobInvite = await createInviteV1(
        bobKeys,
        createContactBundleV2(aliceKeys).v2.keyBundle,
        xmtp.InvitationV1_Context(),
      );

      var aliceInvite = await createInviteV1(
        aliceKeys,
        createContactBundleV2(bobKeys).v2.keyBundle,
        xmtp.InvitationV1_Context(),
      );

      final aliceSharedSecret = compute3DHSecret(
        createECPrivateKey(aliceKeys.identity.privateKey),
        createECPrivateKey(aliceKeys.preKeys[0].privateKey),
        createECPublicKey(bobKeys.identity.encodedPublicKey),
        createECPublicKey(bobKeys.preKeys[0].encodedPublicKey),
        false,
      );

      final bobSharedSecret = compute3DHSecret(
        createECPrivateKey(bobKeys.identity.privateKey),
        createECPrivateKey(bobKeys.preKeys.first.privateKey),
        createECPublicKey(aliceKeys.identity.encodedPublicKey),
        createECPublicKey(aliceKeys.preKeys[0].encodedPublicKey),
        true,
      );

      expect(aliceSharedSecret, bobSharedSecret);

      expect(aliceInvite.topic, bobInvite.topic);
    },
  );

  test(
    skip: skipUnlessTestServerEnabled,
    "v2 messaging: generate deterministic topic/keyMaterial to avoid duplicates",
    () async {
      var aliceWallet = EthPrivateKey.createRandom(Random.secure()).asSigner();
      var bobWallet = EthPrivateKey.createRandom(Random.secure()).asSigner();
      var alice = await _createLocalManager(aliceWallet);
      var bob = await _createLocalManager(bobWallet);
      var bobAddress = bobWallet.address.hex;
      await delayToPropagate();

      // First Alice invites Bob to the conversation
      var c1 = await alice.newConversation(
        bobAddress,
        xmtp.InvitationV1_Context(
          conversationId: "example.com/alice-and-bob",
        ),
      );
      await alice.sendMessage(c1, "Hello Bob");

      // Alice starts the same conversation again (same conversation ID).
      var c2 = await alice.newConversation(
        bobAddress,
        xmtp.InvitationV1_Context(
          conversationId: "example.com/alice-and-bob",
        ),
      );
      await alice.sendMessage(c2, "And another one");

      // Alice should see the same topic and keyMaterial for both conversations.
      expect(c1.topic, c2.topic, reason: "the topic should be deterministic");
      expect(
        c1.invite.aes256GcmHkdfSha256.keyMaterial,
        c2.invite.aes256GcmHkdfSha256.keyMaterial,
        reason: "the keyMaterial should be deterministic",
      );

      // And Bob should only see the one conversation.
      var bobConvos = await bob.listConversations();
      expect(1, bobConvos.length);
      expect(c1.topic, bobConvos[0].topic);

      var bobMessages = await bob.listMessages(bobConvos);
      expect(2, bobMessages.length);
      expect("Hello Bob", bobMessages[1].content);
      expect("And another one", bobMessages[0].content);
    },
  );

  // This creates 2 users connected to the API and having a conversation.
  // It sends a message with invalid payload (bad content signature)
  // to verify that it is properly discarded.
  test(
    skip: skipUnlessTestServerEnabled,
    "v2 messaging: bad signature on a message should be discarded",
    () async {
      var aliceWallet = EthPrivateKey.createRandom(Random.secure()).asSigner();
      var bobWallet = EthPrivateKey.createRandom(Random.secure()).asSigner();
      var alice = await _createLocalManager(aliceWallet);
      var bob = await _createLocalManager(bobWallet);
      var aliceAddress = aliceWallet.address.hex;
      var bobAddress = bobWallet.address.hex;

      var aliceChats = await alice.listConversations();
      var bobChats = await bob.listConversations();
      expect(aliceChats.length, 0);
      expect(bobChats.length, 0);

      // First Alice invites Bob to the conversation
      var aliceConvo = await alice.newConversation(
        bobAddress,
        xmtp.InvitationV1_Context(
          conversationId: "example.com/valid",
        ),
      );
      await delayToPropagate();
      var bobConvo = (await bob.listConversations())[0];
      expect(bobConvo.conversationId, "example.com/valid");

      // Helper to inspect transcript (from Alice's perspective).
      getTranscript() async => (await alice.listMessages([aliceConvo]))
          .reversed
          .map((msg) => '${msg.sender.hex}> ${msg.content}');

      // There are no messages at first.
      expect(await getTranscript(), []);

      // But then Alice sends a message to greet Bob.
      await alice.sendMessage(aliceConvo, "hello Bob, it's me Alice!");
      await delayToPropagate();

      // That first messages should show up in the transcript.
      expect(await getTranscript(), [
        "$aliceAddress> hello Bob, it's me Alice!",
      ]);

      // And when Bob sends a greeting back...
      await bob.sendMessage(bobConvo, "Oh, good to chat with you Alice!");
      await delayToPropagate();

      // ... Bob's message should show up in the transcript too.
      expect(await getTranscript(), [
        "$aliceAddress> hello Bob, it's me Alice!",
        "$bobAddress> Oh, good to chat with you Alice!",
      ]);

      // But when Bob's payload is tampered with...
      // (we simulate this using low-level API calls with a bad payload)
      var original = await TextCodec().encode("I love you!");
      var tampered = await TextCodec().encode("I hate you!");
      var now = nowNs();
      var header = xmtp.MessageHeaderV2(topic: bobConvo.topic, createdNs: now);
      var signed = await signContent(bob.auth.keys, header, original);
      // Here's where we pretend to tamper the payload (after signing).
      signed.payload = tampered.writeToBuffer();
      var tamperedMessage =
          await encryptMessageV2(bobConvo.invite, header, signed);
      await bob.api.client.publish(xmtp.PublishRequest(envelopes: [
        xmtp.Envelope(
          contentTopic: bobConvo.topic,
          timestampNs: now,
          message: xmtp.Message(v2: tamperedMessage).writeToBuffer(),
        )
      ]));
      await delayToPropagate();

      // ... then Alice can inspect the topic directly to sees the bad message.
      var inspecting = await alice.api.client
          .query(xmtp.QueryRequest(contentTopics: [aliceConvo.topic]));
      expect(inspecting.envelopes.length, 3 /* = 2 valid + 1 bad */);

      // ... but when she lists messages the tampered one is properly discarded.
      expect(await getTranscript(), [
        "$aliceAddress> hello Bob, it's me Alice!",
        "$bobAddress> Oh, good to chat with you Alice!",
        // The bad 3rd message was discarded.
      ]);
    },
  );

  test(
    skip: skipUnlessTestServerEnabled,
    timeout: const Timeout.factor(5), // TODO: consider turning off in CI
    "v2 messaging: batch requests should be partitioned to fit max batch size",
    () async {
      var aliceWallet = EthPrivateKey.createRandom(Random.secure()).asSigner();
      var alice = await _createLocalManager(aliceWallet);
      var aliceAddress = aliceWallet.address.hexEip55;

      // Pretend a bunch of people have messaged alice.
      const conversationCount = maxQueryRequestsPerBatch + 5;
      await Future.wait(List.generate(conversationCount, (i) async {
        var wallet = EthPrivateKey.createRandom(Random.secure()).asSigner();
        var user = await _createLocalManager(wallet, debugLogRequests: false);
        var convo = await user.newConversation(
            aliceAddress,
            xmtp.InvitationV1_Context(
              conversationId: "example.com/batch-partition-test-convo-$i",
            ));
        await user.sendMessage(convo, "I am number $i of $conversationCount");
      }));
      await delayToPropagate();

      var convos = await alice.listConversations();
      expect(convos.length, conversationCount);

      var messages = await alice.listMessages(convos);
      expect(messages.length, conversationCount);
    },
  );

  // This connects to the dev network to test decrypting v2 messages
  // NOTE: it requires a private key
  test(
    skip: "manual testing only",
    "dev: v2 message reading - listing invites, decrypting messages",
    () async {
      var api = Api.create(
        host: 'dev.xmtp.network',
        port: 5556,
        isSecure: true,
        debugLogRequests: true,
      );
      var wallet = EthPrivateKey.fromHex("... private key ...").asSigner();
      var auth = AuthManager(wallet.address, api);
      var codecs = CodecRegistry()..registerCodec(TextCodec());
      var contacts = ContactManager(api);
      await auth.authenticateWithCredentials(wallet);
      var v2 = ConversationManagerV2(
        wallet.address,
        api,
        auth,
        codecs,
        contacts,
      );
      var conversations = await v2.listConversations();
      for (var convo in conversations) {
        debugPrint("dm w/ ${convo.peer}");
        var dms = await v2.listMessages([convo]);
        for (var j = 0; j < dms.length; ++j) {
          var dm = dms[j];
          debugPrint("${dm.sentAt} ${dm.sender.hexEip55}> ${dm.content}");
        }
      }
    },
  );
}

// helpers

Future<ConversationManagerV2> _createLocalManager(
  Signer wallet, {
  bool debugLogRequests = kDebugMode,
}) async {
  var api = createTestServerApi(debugLogRequests: debugLogRequests);
  var auth = AuthManager(wallet.address, api);
  var codecs = CodecRegistry()..registerCodec(TextCodec());
  var contacts = ContactManager(api);
  var keys = await auth.authenticateWithCredentials(wallet);
  var myContacts = await contacts.getUserContacts(wallet.address.hex);
  if (myContacts.isEmpty) {
    await contacts.saveContact(keys);
    await delayToPropagate();
  }
  return ConversationManagerV2(
    wallet.address,
    api,
    auth,
    codecs,
    contacts,
  );
}
