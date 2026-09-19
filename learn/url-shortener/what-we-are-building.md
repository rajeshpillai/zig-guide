# What We Are Building

> A URL shortener with real storage, and the two decisions that shape every chapter after this one.

A URL shortener: you hand it a long address, it hands you a short one,
and anyone who follows the short one lands on the long one. It is the
classic first service for a reason. It is small enough to finish and
real enough to need everything a bigger service needs: a database, a
schema, validation, and an HTTP surface with all four verbs.

The finished service speaks five routes:

| Route | Does | Which is |
| --- | --- | --- |
| `POST /links` | shorten a URL, answer with the slug | Create |
| `GET /{slug}` | redirect, and count the hit | Read |
| `GET /links/{slug}` | report target and hit count | Read |
| `PUT /links/{slug}` | point the slug somewhere else | Update |
| `DELETE /links/{slug}` | retire the slug | Delete |

Storage is PostgreSQL, one table:

```sql
CREATE TABLE links (
  id     bigserial PRIMARY KEY,
  slug   text UNIQUE NOT NULL,
  target text NOT NULL,
  hits   bigint NOT NULL DEFAULT 0
);
```

## The shape of it

Every chapter in this project builds one box in this picture, bottom to
top:

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

Read it as two halves. Everything above `Store` is about HTTP: what a
request means and what to answer. Everything below it is about Postgres:
how to say the query and how to read the answer. `Store` is the line
between them, and it is the reason most of this code runs without a
network.

## One request, end to end

There is no JSON anywhere in this service. The body of a `POST` is the
URL itself, and the answer is the slug. That keeps the parsing in the
chapters that are about parsing.

```bash
curl -i -X POST http://127.0.0.1:8080/links \
  --data 'https://ziglang.org'
```

```
HTTP/1.1 201 Created
Content-Length: 2

1
```

The slug is `1` because it is the row id written in base62, not a random
string. Following it is the redirect the whole service exists for:

```bash
curl -i http://127.0.0.1:8080/1
```

```
HTTP/1.1 302 Found
Location: https://ziglang.org
Content-Length: 0
```

And the slug's own record reports where it points and how often it has
been followed:

```bash
curl -i http://127.0.0.1:8080/links/1
```

```
HTTP/1.1 200 OK
Content-Length: 34

1 -> https://ziglang.org (1 hits)
```

Those are not illustrations. They are the exchanges in the routes
chapter's expected output, which CI replays on every build.

## Decision one: no driver

The service talks to Postgres directly, over its wire protocol. The
[cookbook recipe](https://www.ziglang.in/learn/how-to/databases/postgres-wire/) showed that
protocol byte by byte: every message is a tag, a length, and a payload.
This project turns that recipe into something a program can lean on: a
client that connects, authenticates, sends SQL, iterates rows, and
survives errors. That is what a driver is, and writing one small enough
to read removes the last box marked magic between your code and the
database.

## Decision two: the seams

Almost nothing in this project needs a network to run. That is not an
accident; it is the same rule the rest of the guide follows: protocol
code parses from a `Reader`, never from a socket. The Postgres client is
tested against scripted bytes. The slug logic is arithmetic. The HTTP
handlers take request bytes and return response bytes, against a store
interface with an in-memory implementation, the same seam the
[ORM's Repo chapter](https://www.ziglang.in/learn/orm/repo/) used. So those three chapters run
in your browser, checked by CI like every other snippet on this site.

Only the last chapter opens sockets. It assembles the client, the slugs
and the routes into one file, swaps the in-memory store for one that
writes SQL, and serves the whole thing against a real database. CI
compiles that file on every run; you run it on your machine, where a
real Postgres can answer.

## What is deliberately missing

Naming what a small project skips is more honest than hoping nobody
asks, and each gap here is one seam away from this design.

- **Connection pooling.** One connection serves every request, which is
  fine at tutorial scale.
- **The extended query protocol.** Real drivers send parameters
  separately from SQL. This project quotes values into SQL text, does it
  carefully, and the client chapter says exactly what the tradeoff is.
- **SCRAM authentication.** The client speaks cleartext password auth,
  which is what a default local Postgres accepts from loopback. The
  client chapter names what production adds.
- **Users and rate limits.** Nothing here knows who you are.

The [web server track](https://www.ziglang.in/learn/web-server/server/) covers the HTTP side
in full depth; this project reuses its ideas in miniature and keeps the
focus on the storage path.
