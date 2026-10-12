# OMP IRC messages in the timeline

Protocol reference checked 12 October 2026 against Paseo v0.11.2, tag commit
[`7595325`](https://github.com/getpaseo/paseo/releases/tag/v0.11.2), and the
custom-context mapping merged in
[Paseo PR #6090](https://github.com/getpaseo/paseo/pull/6090) (commit
`d827588`). OMP's incoming IRC message is an OMP custom message with type
`irc:incoming`; auto-replies use `irc:autoreply`. The message text contains the
rendered `<irc>` block and the sender ID. OMP's event stream documents
`irc_message` as the event for these injected records.

Paseo v0.11.0 and later maps visible OMP custom messages to completed
`tool_call` timeline items named after their custom type, for both live events
and restored history. Oesap maps these existing tool calls to native disclosure
cards, labels `irc:incoming` as “Incoming IRC message” and `irc:autoreply` as
“IRC auto-reply”, and shows the sender on the collapsed row when it can read it
from the text. Expanding the card retains the full OMP-provided message and
instructions. No new Paseo capability flag or wire message is involved.

Daemon compatibility: the OMP custom-message-to-tool-call mapping is present in
Paseo v0.11.0 and later. Older daemons that expose the same injected context as
assistant text remain readable as ordinary messages; Oesap does not infer an
IRC message by parsing arbitrary assistant prose.
