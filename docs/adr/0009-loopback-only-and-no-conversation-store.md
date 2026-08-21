# The engine's address is loopback, and its conversations are not stored

Two decisions with one subject: what leaves this machine. Neither is a limitation the engine
switch happened to arrive with — both are what keeps «текст никогда не покидает машину» a
property of the code rather than of somebody's care.

## Only the port is settable

`ModelEngine` carries a `defaultPort`; `AppSettings.enginePort` lets a person change it; the
host is written once, in `LMStudioClient.baseURL(port:)` and in `ClientPool.ollama(port:)`, and
it is `127.0.0.1` both times. There is no field for it and no setting behind it.

The alternative — a free-text address, which is what «engine on port N» invites — was rejected
because of what it converts. Today the promise is checkable by reading two lines of code. With
an address field it becomes a promise about what a user typed into it, and the app has no way to
tell `127.0.0.1:1234` from a host on the far side of a VPN that happens to answer the same
protocol. That is not a hypothetical shape of mistake: LM Studio ships a «Serve on Local
Network» switch, so an address that works is easy to produce.

What this costs, stated plainly: a person running LM Studio on a second Mac cannot point this app
at it. If that is ever wanted it is a new decision with its own record — including what the
window says while it is pointed off-machine — and not an extension of this one. «Port only for
now» would have been the same field, deferred.

## `store: false` on every LM Studio request

`/api/v1/chat` has a `store` field and it defaults to **`true`**: the server keeps the
conversation and hands back a `response_id`. Every request this app makes sends `false`
(`LMStudioChatBody`, pinned by a test).

The text still never leaves the machine either way, so this is a narrower point: with `store`
left alone, every translation this app performs accumulates a second copy inside another
application's storage, where the user did not put it and this app cannot remove it. «Толмач»
writes to disk in exactly one place — `TranslatedFileWriter`, under a name `OutputNaming`
chooses, next to the source the user dropped — and it does not get to acquire a second one by
omission.

The same reasoning covers what is *not* sent: `previous_response_id`, and any use of the
stateful-chat endpoints. A translation is one request and one reply; nothing here needs a
server-side thread, so nothing here creates one.

## Consequences

- The «Модели» pane shows the whole address it is calling (`127.0.0.1:<port>`) beside the port
  field. It is built from the same setting the client uses, so the two cannot disagree — the
  reason the old «Адрес» row read `OllamaClient.defaultBaseURL` rather than a literal.
- A test asserts the host is loopback whatever the port
  (`aPortChangesTheAddressAndTheHostStaysOnLoopback`), and another that `store: false` is in
  every body (`everyRequestAsksTheServerNotToStoreTheConversation`). Both are cheap; both would
  otherwise be the kind of property that quietly stops being true.
- Nothing in this app can be pointed at a paid API by configuration. That is the point.

## Where the code is

`Sources/TranslatorApp/ModelEngine.swift` (the ports),
`Sources/TranslatorApp/EngineRouter.swift` (`ClientPool`),
`Sources/LMStudioKit/LMStudioClient.swift` (`baseURL(port:)`),
`Sources/LMStudioKit/LMStudioChatBody.swift` (`store`), and
`docs/design/specs/2026-08-21-model-engine-switch-design.md` §6.1 and §5.3.
