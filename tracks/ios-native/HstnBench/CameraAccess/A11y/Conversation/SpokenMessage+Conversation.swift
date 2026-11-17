/*
 * SpokenMessage+Conversation - what the app says, in its own voice, around a Realtime conversation
 *
 * Inside the conversation the model speaks for itself (its greeting confirms it's listening, its
 * goodbye ends it). These lines cover the edges the model can't: no key, no mic, a refused key,
 * a dropped connection, and the end after silence or the button.
 */

extension SpokenMessage {
  static let conversationNeedsKey =
    "Talking needs an OpenAI key, and there isn't one yet. Ask a sighted helper to add one in Settings, under OpenAI key. You can still say read."
  static let conversationNoMic = "I couldn't open the microphone for talking. Voice commands are back on."
  static let conversationKeyRefused = "OpenAI turned down the key, so I can't talk right now. Voice commands are back on."
  static let conversationOutOfCredit = "The OpenAI account is out of credit, so I can't talk right now. Voice commands are back on."
  static let conversationLost = "I lost the connection, so I've stopped talking. Say talk to try again."
  static let conversationEnded = "Finished talking. Say talk to start again."
}
