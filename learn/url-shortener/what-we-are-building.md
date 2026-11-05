# What You Will Build

> A URL shortener with real storage, and the two decisions that control all the chapters after this one.

A URL shortener works like this: you give it a long address, and it gives you
a short address. When a person follows the short address, the person gets to
the long address. A URL shortener is a common first service. It is small
enough to complete. But it needs all the parts that a larger service needs: a
database, a schema, validation, and an HTTP surface with all four verbs.

The completed service has five routes:

| Route | Action | Operation |
| --- | --- | --- |
| `POST /links` | shorten a URL, answer with the slug | Create |
| `GET /{slug}` | redirect, and count the hit | Read |
| `GET /links/{slug}` | report target and hit count | Read |
| `PUT /links/{slug}` | point the slug to a different target | Update |
| `DELETE /links/{slug}` | retire the slug | Delete |

The storage is PostgreSQL, with one table:

```sql
CREATE TABLE links (
  id     bigserial PRIMARY KEY,
  slug   text UNIQUE NOT NULL,
  target text NOT NULL,
  hits   bigint NOT NULL DEFAULT 0
);
```

## The design

Each chapter in this project builds one box in this diagram, from the bottom
to the top:

```
Browser / curl
      │
      ▼
 HTTP Server
      │
      ▼
   Routes ──────────► Slug logic
      │
      ▼
    Store
      │
      ▼
Postgres Client
      │
  TCP socket
      │
      ▼
  PostgreSQL
```

The diagram has two halves:

- All the boxes above `Store` are about HTTP: what a request means, and what
  to answer.
- All the boxes below `Store` are about Postgres: how to send the query, and
  how to read the answer.

`Store` is the line between the two halves. Because of `Store`, most of this
code runs without a network.

## One request, from start to end

This service uses no JSON. The body of a `POST` is the URL, and the answer is
the slug. Thus the parsing stays in the chapters that are about parsing.

```bash
curl -i -X POST http://127.0.0.1:8080/links \
  --data 'https://ziglang.org'
```

```
HTTP/1.1 201 Created
Content-Length: 2

1
```

The slug is `1` because the slug is the row id in base62. It is not a random
string. When you follow the slug, you get the redirect. The redirect is the
main task of the service:

```bash
curl -i http://127.0.0.1:8080/1
```

```
HTTP/1.1 302 Found
Location: https://ziglang.org
Content-Length: 0
```

The record of the slug reports the target and how many times people followed
the slug:

```bash
curl -i http://127.0.0.1:8080/links/1
```

```
HTTP/1.1 200 OK
Content-Length: 34

1 -> https://ziglang.org (1 hits)
```

The expected output of the routes chapter contains these same exchanges, and
CI replays them on each build.

## Decision one: no driver

The service talks to Postgres directly, over the Postgres wire protocol. The
[cookbook recipe](https://www.ziglang.in/learn/how-to/databases/postgres-wire/) showed each byte of
that protocol. Each message is a tag, a length, and a payload. This project
changes that recipe into a client that a program can use. The client does
these tasks:

- Connect.
- Authenticate.
- Send SQL.
- Iterate over rows.
- Continue after errors.

That is what a driver is. When the driver is small enough to read, you can see
all of the path between your code and the database.

## Decision two: the seams

Almost no part of this project needs a network. This follows the rule for all
of the guide: protocol code parses from a `Reader`, never from a socket.

- The tests of the Postgres client use scripted bytes.
- The slug logic is arithmetic.
- The HTTP handlers take request bytes and return response bytes. They use a
  store interface with an in-memory implementation. This is the same seam that
  the [ORM's Repo chapter](https://www.ziglang.in/learn/orm/repo/) used.

Thus those three chapters run in your browser, and CI checks them the same as
each other snippet on this site.

Only the last chapter opens sockets. That chapter puts the client, the slugs
and the routes into one file. It replaces the in-memory store with a store that
writes SQL. Then it serves the full service against a real database. CI
compiles that file on each run. You run the file on your computer, where a real
Postgres can answer.

## What this project does not include

This small project does not include some features. You can add each of these
features behind one of the seams in this design.

- **Connection pooling.** One connection serves all requests. This is
  sufficient for a tutorial.
- **The extended query protocol.** Real drivers send parameters separately from
  the SQL. This project quotes values into the SQL text, and does this
  carefully. The client chapter states the tradeoff exactly.
- **SCRAM authentication.** The client uses cleartext password auth. A default
  local Postgres accepts that auth from loopback. The client chapter states
  what production adds.
- **Users and rate limits.** No part of this service knows who you are.

The [web server track](https://www.ziglang.in/learn/web-server/server/) explains the HTTP side in
full. This project uses the ideas from that track in a smaller form, and stays
on the storage path.
