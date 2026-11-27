# What You Will Build

> A chat room over WebSocket with only the standard library, and the four decisions that the next chapters make.

This project builds a chat room. A client connects over WebSocket and picks
a nickname. Then each message that a member sends goes to each member of the
room. When a member joins or leaves, the others see a notice.

The server uses only the Zig standard library. It uses the parts from the
four WebSocket chapters of Networking:

- [The WebSocket Handshake](https://www.ziglang.in/learn/networking/websocket-handshake/): the
  server answers the upgrade with `std.http.Server`.
- [WebSocket Frames](https://www.ziglang.in/learn/networking/websocket-frames/): the header, the
  length forms and the mask.
- [A WebSocket Client](https://www.ziglang.in/learn/networking/websocket-client/): the client in
  the last chapter of this project is that client, imported from its file.
- [A WebSocket Server on a Socket](https://www.ziglang.in/learn/networking/websocket-server/): the
  gaps in std that this project must fill.

Read those four first if WebSocket is new to you.

## The parts

The server has four parts. Each part is one file, and each file is a snippet
that CI compiles and runs:

| File | What it does | Runs where |
|---|---|---|
| `chat-protocol.zig` | Parses commands from clients and formats events for clients | browser |
| `chat-hub.zig` | Keeps the members and copies each line into their outboxes | browser |
| `chat-frames.zig` | Reads frames from a client, with fragments and close codes | browser |
| `chat-server.zig` | Puts the parts on real sockets, with three clients | native |

The first three files take bytes and return bytes. They never see a socket,
thus their chapters run in your browser. The last file imports the other
three and adds the sockets and the tasks.

## Four decisions

A chat server looks simple: read a message, and send it to everybody. Four
questions make it difficult, and each chapter answers one of them.

1. **What does a message mean?** WebSocket frames the bytes. It does not
   say what the bytes mean. [The Protocol](https://www.ziglang.in/learn/chat-server/protocol/)
   defines a small text protocol.
2. **Who writes to a socket?** Each member receives lines from many other
   members, and each sender runs in a different task. If two tasks write to
   one socket at the same time, the frames can mix.
   [The Hub](https://www.ziglang.in/learn/chat-server/hub/) gives each connection one writer.
3. **What if a client does not read?** A broadcast that waits for one slow
   member stops the room. [Slow Clients](https://www.ziglang.in/learn/chat-server/slow-clients/)
   drops that member instead.
4. **What does std not read?** std refuses a message in fragments and does
   not return the close code.
   [Read the Frames Yourself](https://www.ziglang.in/learn/chat-server/frames/) writes the reader
   that the server needs.

[The Server](https://www.ziglang.in/learn/chat-server/the-server/) puts the four answers on real
sockets.

## What it does not do

The room is one room, with up to eight members. It keeps no history, so a
new member sees only the messages that arrive after the member joins. It has no
accounts, no TLS and no persistence. Each of those is a separate decision,
and none of them changes the four parts above.
