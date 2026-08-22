# Transports

**What you'll be able to do after this:** explain, with numbers, why TCP head-of-line blocking
makes a WebSocket a bad media transport and exactly when it is nonetheless the right choice;
size Opus, PLC, FEC and DTX against a real loss profile; design a binary audio-over-WebSocket
subprotocol that does not repeat the usual mistakes; and read Twilio Media Streams' actual
payload and price its overhead.

---

## 1. Intuition

Every general-purpose network protocol optimises for delivering all the bytes. Real-time audio
wants something different: **deliver the bytes that are still useful, and discard the rest.**

A 20 ms audio frame has a playout deadline. If it arrives after the moment it should have been
played, it is worthless — the receiver has already concealed the gap and moved on. So for
audio, "late" and "lost" are the same outcome, and a transport that guarantees delivery by
retransmitting is trading a cheap failure (one concealed frame) for an expensive one (a stall
in the whole stream).

That is the entire argument for UDP-based media, and it is not a preference. TCP delivers bytes
**in order**: a lost segment stops the receiving application from seeing anything behind it
until the retransmission arrives, at least one round trip later. The audio behind the loss was
already on the receiver's machine; TCP refuses to hand it up. Measured below: at 5% loss and
200 ms RTT, TCP delivers 100% of the frames and only **66.1%** of them are usable, while plain
RTP loses 4.9% and delivers 95.1% usable — and RTP with Opus in-band FEC reaches **99.8%**.

Four transports appear in real voice systems, and they answer different questions: WebRTC for
the browser and anything crossing the public internet, SIP/RTP for the telephone network,
WebSocket for server-to-server hops and vendor APIs, and gRPC for internal service calls that
are not carrying the live media edge.

---

## 2. Rigour

### 2.1 The deadline model

Let frame $i$ be captured at $t_i = i \cdot 20$ ms and played at $t_i + D$, where $D$ is the
total playout delay the receiver has chosen: one-way network delay plus jitter buffer
([`02-webrtc-internals.md`](02-webrtc-internals.md)). Frame $i$ is **usable** iff it is
delivered to the application before $t_i + D$.

$$
\text{usable}_i = \mathbb{1}\left[\,\text{deliver}(i) \le t_i + D\,\right]
$$

Two properties follow immediately. Increasing $D$ converts lateness into latency — you can
always make more frames usable by delaying playout, and every millisecond comes straight out of
the conversational budget
([`../01-foundations/04-latency-budget.md`](../01-foundations/04-latency-budget.md)). And a
transport's quality is not its loss rate, it is the distribution of $\text{deliver}(i) - t_i$;
a transport with 0% loss and a heavy tail is worse than one with 3% loss and none.

### 2.2 TCP head-of-line blocking, derived

TCP hands bytes to the application in order, so the delivery time of frame $i$ is not its own
arrival time but the maximum arrival time of everything up to and including it:

$$
\text{deliver}_{\text{TCP}}(i) = \max_{j \le i} \text{arrive}(j)
$$

A single lost segment adds at least one RTT (fast retransmit; an RTO timeout is much worse) to
$\text{arrive}(j)$, and that delay propagates to every subsequent frame until the stream drains
the backlog. The number of frames damaged by one loss is roughly

$$
n_{\text{damaged}} \approx \frac{\text{RTT}}{20\ \text{ms}}
$$

so one loss at 200 ms RTT damages ten frames — 200 ms of audio — which is why the measured
late-rate at 5% loss is 33.9% rather than 5%. **Loss and lateness are not proportional under
TCP; they are amplified by RTT/frame-duration.**

`[MEASURED]` from §3, 3000 frames, 60 ms jitter buffer:

| Loss / RTT | Transport | p50 | p95 | p99 | Late | Concealed | Usable |
|---|---|---|---|---|---|---|---|
| 1% / 60 ms | RTP | 35.4 | 45.4 | 50.2 | 0.0% | 0.7% | 99.3% |
| | RTP+FEC | 35.4 | 45.9 | 52.0 | 0.0% | 0.0% | **100.0%** |
| | TCP | 35.5 | 47.2 | 74.8 | 0.7% | 0.0% | 99.3% |
| 3% / 120 ms | RTP | 65.4 | 75.4 | 80.2 | 0.0% | 2.6% | 97.4% |
| | RTP+FEC | 65.5 | 78.0 | 87.0 | 0.0% | 0.1% | **99.9%** |
| | TCP | 66.6 | 160.4 | 186.8 | 10.1% | 0.0% | 89.9% |
| 5% / 200 ms | RTP | 105.4 | 115.4 | 120.2 | 0.0% | 4.9% | 95.1% |
| | RTP+FEC | 105.6 | 120.7 | 129.3 | 0.0% | 0.2% | **99.8%** |
| | TCP | 110.5 | 299.9 | 309.8 | 33.9% | 0.0% | **66.1%** |

At 1% loss on a low-RTT link, TCP is fine — 99.3% usable, identical to plain RTP. The
divergence appears with RTT and loss together, which is exactly the profile of a mobile network
or a long-haul path.

### 2.3 Opus: what the codec does about loss

Verified against RFC 6716 (Valin, Vos, Terriberry, 2012).

**Frame size.** Opus supports 2.5–60 ms frames and packets up to 120 ms, and the RFC is
explicit that "20 ms frames are a good choice for most applications": longer frames amortise
header overhead and improve coding efficiency, but "losing one packet constitutes a loss of a
bigger chunk of audio". This is the origin of the 20 ms frame contract used throughout this
curriculum ([`../00-setup/03-canonical-formats.md`](../00-setup/03-canonical-formats.md)).

**Algorithmic delay.** The SILK (LP) layer needs 5 ms of look-ahead plus up to 1.5 ms for
resampling; the CELT (MDCT) layer needs 2.5 ms. So a 20 ms Opus frame costs 22.5–26.5 ms of
delay before a byte leaves the encoder, and that is a floor, not a tuning parameter.

**Bitrate.** 6–510 kbit/s overall, with 20 ms sweet spots of 8–12 kbit/s narrowband speech,
16–20 kbit/s wideband speech, 28–40 kbit/s fullband speech.

**PLC** conceals a missing frame by extrapolating the previous one. It works well for one frame
and degrades audibly across consecutive losses, which is why burst loss matters far more than
average loss.

**In-band FEC** re-encodes perceptually important frames at a lower bitrate and attaches the
copy to a *subsequent* packet. Two consequences the RFC makes plain and that people miss: it
costs bitrate, and it costs **one frame of delay**, because the redundant copy cannot be used
until the next packet arrives. In the measurement above, that delay is absorbed entirely by a
60 ms jitter buffer while concealment drops from 4.9% to 0.2%. FEC is nearly free when you
already have a jitter buffer, and useless if you do not.

**DTX** encodes "only one frame every 400 milliseconds" during silence. In a voice agent each
party is silent roughly half the time, so DTX removes something close to half the packets in
each direction — significant at the packet rates in §5, and a source of confusion when a
naive receiver treats the gap as a disconnect.

### 2.4 What a frame costs on the wire

`[MEASURED]` from §3, one 20 ms frame, IPv4:

| Stack | Audio bytes | Payload | Headers | Wire | kbit/s | Wire vs audio |
|---|---|---|---|---|---|---|
| Opus / SRTP / UDP / IP | 50 | 50 | 50 | 100 | 40.0 | 2.00× |
| Opus / WS / TLS / TCP / IP | 50 | 50 | 75 | 125 | 50.0 | 2.50× |
| PCMU / RTP / UDP / IP | 160 | 160 | 40 | 200 | 80.0 | 1.25× |
| PCMU / WS / TLS / TCP / IP | 160 | 160 | 75 | 235 | 94.0 | 1.47× |
| **Twilio JSON + base64** | 160 | 382 | 75 | 457 | **182.8** | **2.86×** |

Three readings. For a well-compressed codec at 20 ms, **headers are as large as the payload** —
this is the real reason people are tempted by longer frames, and the reason the RFC pushes back.
The Twilio row is the cost of a text protocol carrying binary: base64 inflates 160 bytes to 216
(1.33×), the JSON envelope adds another 166 bytes, and the wire cost is 2.86× the audio. And
G.711 over WebSocket at 94 kbit/s is *cheaper* than Twilio's JSON at 182.8 kbit/s for exactly
the same audio, which is the price of a human-readable protocol.

### 2.5 The four transports

| Axis | WebRTC | SIP/RTP | WebSocket | gRPC |
|---|---|---|---|---|
| Transport | UDP (DTLS-SRTP), TCP/TLS fallback | UDP (RTP), TCP for signalling | TCP | HTTP/2 over TCP |
| Head-of-line blocking | no | no | yes | yes, twice (TCP + stream) |
| Loss handling | PLC, FEC, RED, NACK, congestion control | PLC, sometimes FEC | none — retransmit | none — retransmit |
| Jitter buffer | built in (NetEQ) | in the endpoint | you build it | you build it |
| Echo cancellation | client-side APM available | in the phone/gateway | your problem | your problem |
| NAT traversal | ICE/STUN/TURN | SIP ALG, SBCs, pain | trivial (outbound TCP) | trivial |
| Encryption | mandatory DTLS-SRTP | optional SRTP/TLS | TLS | TLS |
| Browser | native | no | native | no (needs grpc-web) |
| Ops burden | high (TURN, SFU) | high (SBC, trunks) | low | low |
| Right for | browser and app clients | the PSTN | server↔server, vendor APIs | internal RPC, ASR/TTS backends |

### 2.6 When a WebSocket is genuinely fine

The measurement gives the condition rather than an opinion. TCP's damage scales with
$\text{loss} \times \text{RTT}$, so a WebSocket is fine when both are small:

- **Inside one datacentre or VPC.** Loss on the order of $10^{-5}$, RTT under 1 ms. The 1%/60 ms
  row already shows 99.3% usable; a LAN is orders of magnitude better. This is why streaming
  ASR and TTS vendor APIs are WebSockets and nobody suffers.
- **When the lossy leg is somebody else's problem.** With Twilio Media Streams the audio has
  already crossed the PSTN and been reassembled by the carrier; your WebSocket runs from
  Twilio's cloud to your server over well-provisioned paths.
- **Prototypes and internal tools**, where a 200 ms glitch during a demo is not a business risk.

It is *not* fine for a browser or mobile client on the public internet, which is precisely
where people reach for it because it is easy. The failure is invisible in testing on a good
network and severe on a train.

### 2.7 Designing an audio-over-WebSocket subprotocol

If you must, design it properly. The recurring mistakes are JSON envelopes around base64 audio,
no sequence numbers, control messages on a different channel from the audio they refer to, and
no flow control.

**Use binary frames with a fixed header.** A workable 12-byte layout:

| Offset | Size | Field | Purpose |
|---|---|---|---|
| 0 | 1 | version | protocol evolution without a handshake round trip |
| 1 | 1 | type | `0x01` audio, `0x02` control, `0x03` transcript, `0x04` mark |
| 2 | 2 | flags | codec id, DTX marker, end-of-utterance |
| 4 | 4 | sequence | detect loss and reordering; the transport will not tell you |
| 8 | 4 | timestamp\_ms | media clock, independent of arrival time |
| 12 | n | payload | raw codec bytes, never base64 |

**Keep control in band with the media.** An `interrupt` sent on a side channel races the audio
frames it is meant to cut off. In-band ordering makes "stop at exactly this sample" expressible
([`03-pipeline-architecture.md`](03-pipeline-architecture.md)).

**Model playback explicitly.** The sender must learn what the receiver actually played, or
barge-in truncation is guesswork
([`../03-turn-taking/04-barge-in.md`](../03-turn-taking/04-barge-in.md)). Two messages suffice:
a `mark` the sender inserts into the audio stream and the receiver echoes when it reaches it,
and a `clear` that drops everything buffered and un-played. Twilio's protocol has exactly these,
and that is not a coincidence (§2.8).

**Bound the buffers.** TCP will happily accept megabytes into kernel and userspace buffers, so
an overloaded receiver accumulates a growing audio backlog instead of dropping frames — you get
seconds of latency instead of a glitch. Cap the outstanding unplayed audio in milliseconds, and
drop or trim past it.

**Handle reconnection as resume, not restart.** Carry the last acknowledged sequence number so a
reconnect can resume the media clock rather than restarting the session
([`07-reliability.md`](07-reliability.md)).

**Heartbeat at the application layer.** TCP will hold a dead connection open for minutes. A
silent-but-alive audio stream (DTX) is indistinguishable from a hung peer without an explicit
ping.

### 2.8 Twilio Media Streams, precisely

Verified against Twilio's WebSocket Messages documentation, retrieved 2026-08-22.

Twilio sends `connected`, `start`, `media`, `dtmf`, `stop`, and `mark`. The `start` message
fixes the format for the whole stream: `mediaFormat.encoding` is **always** `audio/x-mulaw`,
`sampleRate` **always** `8000`, `channels` **always** `1`. So the telephony edge in this
curriculum's contract is not a choice, it is the wire format
([`../00-setup/03-canonical-formats.md`](../00-setup/03-canonical-formats.md)).

Each `media` message carries `media.track` (`inbound`/`outbound`), `media.chunk`,
`media.timestamp` (presentation time in ms from stream start), and `media.payload`, base64 of
raw µ-law. Your server can send back `media`, `mark`, and `clear`. Three details that decide
whether an integration works:

- **`clear` is the barge-in primitive.** Twilio buffers everything you send and plays it in
  order, so cancelling a reply means sending `clear`; simply stopping your writes leaves
  seconds of already-sent audio to play out.
- **`mark` is the playback-position oracle.** Send a `mark` after a chunk and Twilio echoes it
  when that chunk finishes playing — which is how you learn what the caller actually heard, for
  the transcript-truncation rule in
  [`../03-turn-taking/04-barge-in.md`](../03-turn-taking/04-barge-in.md). After a `clear`,
  Twilio returns the marks it will *not* play, so you can compute the boundary exactly.
- **No file headers.** The docs warn explicitly that a WAV/RIFF header in `media.payload`
  "causes the media to be streamed incorrectly". Send raw samples.

The cost is the 2.86× wire inflation in §2.4, and one more thing: `sequenceNumber` exists
because a text protocol over a reliable stream still needs ordering semantics its transport does
not express.

### 2.9 gRPC, and where it belongs

gRPC's bidirectional streams look ideal for audio and are not, for the media edge: HTTP/2 runs
over TCP, so a loss blocks the connection exactly as in §2.2, and HTTP/2's own stream
multiplexing adds a second head-of-line layer when several streams share a connection. Where it
is genuinely good is service-to-service inside your network — an ASR or TTS backend behind a
typed schema with flow control and deadlines, on a link where loss is negligible. That is the
same conclusion as §2.6 with a better IDL.

---

## 3. From scratch

Wire cost and deadline behaviour for three transports. Standalone, stdlib only, deterministic.

```python
"""What each transport costs: bytes on the wire, and frames that miss their deadline.

Part A prices one 20 ms audio frame on RTP/UDP, on a raw binary WebSocket, and on
Twilio Media Streams' JSON+base64 envelope, from real header sizes.

Part B simulates delivery over a lossy link for three transports -- plain RTP,
RTP with Opus in-band FEC, and TCP (any WebSocket) -- and counts the frames that
arrive after their playout deadline. TCP loses nothing and is late constantly;
that is head-of-line blocking, and it is why audio does not run on TCP.
"""

import base64
import json
import random

FRAME_MS = 20
FRAMES_PER_S = 1000 // FRAME_MS

# ---------------------------------------------------------------- Part A
IP4, UDP, RTP_HDR, TCP_HDR = 20, 8, 12, 20
TLS_REC = 29            # TLS 1.3 AEAD record overhead (5 header + 16 tag + 8 nonce/pad)
WS_HDR_CLIENT = 6       # 2 byte header + 4 byte mask (client->server)
SRTP_TAG = 10           # SRTP authentication tag, default profile

OPUS_WB_BPS = 20_000    # RFC 6716 sweet spot for wideband speech at 20 ms
MULAW_8K_BPS = 64_000   # G.711 telephony


def per_frame_bytes(bps):
    return bps * FRAME_MS // 8000


def twilio_media_frame(pcmu_bytes):
    """The exact JSON Twilio sends per 20 ms of audio (docs, 2026-08-22)."""
    return json.dumps({
        "event": "media",
        "sequenceNumber": "1234",
        "media": {"track": "inbound", "chunk": "1234", "timestamp": "12345",
                  "payload": base64.b64encode(b"\xff" * pcmu_bytes).decode()},
        "streamSid": "MZ" + "0" * 32,
    }, separators=(",", ":"))


def part_a():
    opus = per_frame_bytes(OPUS_WB_BPS)      # 50 bytes
    pcmu = per_frame_bytes(MULAW_8K_BPS)     # 160 bytes
    twilio = twilio_media_frame(pcmu)
    rows = [
        ("Opus/SRTP/UDP/IP", opus, opus, IP4 + UDP + RTP_HDR + SRTP_TAG),
        ("Opus/WS/TLS/TCP/IP", opus, opus, IP4 + TCP_HDR + TLS_REC + WS_HDR_CLIENT),
        ("PCMU/RTP/UDP/IP", pcmu, pcmu, IP4 + UDP + RTP_HDR),
        ("PCMU/WS/TLS/TCP/IP", pcmu, pcmu, IP4 + TCP_HDR + TLS_REC + WS_HDR_CLIENT),
        ("Twilio JSON+base64", pcmu, len(twilio), IP4 + TCP_HDR + TLS_REC + WS_HDR_CLIENT),
    ]
    print(f"{'stack':22s} {'audio B':>8} {'payload B':>10} {'header B':>9} {'wire B':>7} "
          f"{'kbit/s':>8} {'vs audio':>9}")
    for name, audio, payload, hdr in rows:
        wire = payload + hdr
        print(f"{name:22s} {audio:8d} {payload:10d} {hdr:9d} {wire:7d} "
              f"{wire * 8 * FRAMES_PER_S / 1000:8.1f} {wire / audio:8.2f}x")
    print(f"\nTwilio media message is {len(twilio)} bytes of JSON carrying {pcmu} bytes "
          f"of audio ({len(twilio)/pcmu:.2f}x inflation)")
    print(f"base64 of {pcmu} bytes = {len(base64.b64encode(b'x' * pcmu))} chars "
          f"({4/3:.2f}x), the JSON envelope adds "
          f"{len(twilio) - len(base64.b64encode(b'x' * pcmu))} bytes")


# ---------------------------------------------------------------- Part B
N_FRAMES = 3000                 # 60 seconds of audio
JITTER_BUFFER_MS = 60           # playout delay the receiver adds
SEED = 5


def simulate(transport, loss, rtt_ms, jitter_ms=8.0):
    """Return per-frame (delivery_time - send_time) in ms, and a 'concealed' count.

    Time base: frame i is sent at i*FRAME_MS. One-way delay is rtt/2 plus jitter.
    """
    rng = random.Random(SEED)
    owd = rtt_ms / 2
    delivered, concealed, prev_deliverable = [], 0, 0.0
    lost_prev = False
    for i in range(N_FRAMES):
        sent = i * FRAME_MS
        arrive = sent + owd + abs(rng.gauss(0, jitter_ms))
        drop = rng.random() < loss

        if transport == "rtp":
            if drop:
                concealed += 1
                lost_prev = True
                continue
            delivered.append((i, arrive - sent))
        elif transport == "rtp+fec":
            # Opus in-band FEC: a lost frame is recovered from the NEXT packet, so it
            # is available one frame later -- unless that packet is lost too.
            if drop:
                if lost_prev:
                    concealed += 1        # two in a row: unrecoverable
                else:
                    delivered.append((i, arrive + FRAME_MS - sent))
                lost_prev = True
                continue
            lost_prev = False
            delivered.append((i, arrive - sent))
        else:  # tcp: nothing is lost, everything behind a loss waits
            if drop:
                arrive += rtt_ms          # fast retransmit costs one round trip
            # in-order delivery: this byte range cannot be handed up before the last
            deliverable = max(arrive, prev_deliverable)
            prev_deliverable = deliverable
            delivered.append((i, deliverable - sent))
    return delivered, concealed


def report(loss, rtt):
    print(f"\nloss {loss:.1%}, RTT {rtt} ms, jitter buffer {JITTER_BUFFER_MS} ms, "
          f"{N_FRAMES} frames")
    print(f"{'transport':10s} {'p50':>7} {'p95':>7} {'p99':>7} {'max':>8} "
          f"{'late':>7} {'concealed':>10} {'usable':>8}")
    for t in ("rtp", "rtp+fec", "tcp"):
        d, concealed = simulate(t, loss, rtt)
        lat = sorted(x for _, x in d)
        deadline = rtt / 2 + JITTER_BUFFER_MS
        late = sum(1 for x in lat if x > deadline)
        usable = (len(d) - late) / N_FRAMES
        print(f"{t:10s} {lat[len(lat)//2]:7.1f} {lat[int(.95*len(lat))]:7.1f} "
              f"{lat[int(.99*len(lat))]:7.1f} {max(lat):8.1f} "
              f"{late/N_FRAMES:6.1%} {concealed/N_FRAMES:9.1%} {usable:7.1%}")


if __name__ == "__main__":
    print("PART A -- one 20 ms frame on the wire\n")
    part_a()
    print("\n\nPART B -- delivery under loss (a frame is usable only if it arrives "
          "before its playout deadline)")
    for loss, rtt in ((0.01, 60), (0.03, 120), (0.05, 200)):
        report(loss, rtt)
```

Output `[MEASURED]`:

```
PART A -- one 20 ms frame on the wire

stack                   audio B  payload B  header B  wire B   kbit/s  vs audio
Opus/SRTP/UDP/IP             50         50        50     100     40.0     2.00x
Opus/WS/TLS/TCP/IP           50         50        75     125     50.0     2.50x
PCMU/RTP/UDP/IP             160        160        40     200     80.0     1.25x
PCMU/WS/TLS/TCP/IP          160        160        75     235     94.0     1.47x
Twilio JSON+base64          160        382        75     457    182.8     2.86x

Twilio media message is 382 bytes of JSON carrying 160 bytes of audio (2.39x inflation)
base64 of 160 bytes = 216 chars (1.33x), the JSON envelope adds 166 bytes


PART B -- delivery under loss (a frame is usable only if it arrives before its playout deadline)

loss 1.0%, RTT 60 ms, jitter buffer 60 ms, 3000 frames
transport      p50     p95     p99      max    late  concealed   usable
rtp           35.4    45.4    50.2     58.4   0.0%      0.7%   99.3%
rtp+fec       35.4    45.9    52.0     61.2   0.0%      0.0%  100.0%
tcp           35.5    47.2    74.8    101.2   0.7%      0.0%   99.3%

loss 3.0%, RTT 120 ms, jitter buffer 60 ms, 3000 frames
transport      p50     p95     p99      max    late  concealed   usable
rtp           65.4    75.4    80.2     88.4   0.0%      2.6%   97.4%
rtp+fec       65.5    78.0    87.0     97.5   0.0%      0.1%   99.9%
tcp           66.6   160.4   186.8    197.5  10.1%      0.0%   89.9%

loss 5.0%, RTT 200 ms, jitter buffer 60 ms, 3000 frames
transport      p50     p95     p99      max    late  concealed   usable
rtp          105.4   115.4   120.2    128.4   0.0%      4.9%   95.1%
rtp+fec      105.6   120.7   129.3    145.1   0.0%      0.2%   99.8%
tcp          110.5   299.9   309.8    325.1  33.9%      0.0%   66.1%
```

Three load-bearing details. **`prev_deliverable` is the whole of head-of-line blocking** — one
`max()` over the delivery history is the entire difference between TCP and UDP for audio, and it
is why the TCP row's p50 looks healthy while its p95 does not. **The FEC branch adds one frame
of delay, not one round trip**, because the redundant copy rides the *next* packet rather than
being requested; modelling it as a retransmission would make FEC look useless when it is the
best row in the table. And **`usable` counts late frames as lost**, which is the only definition
that matches what the listener hears; reporting delivery rate instead is how a TCP transport
passes a network test and fails a call.

---

## 4. How production does it

**LiveKit** puts WebRTC at the client edge and terminates it in a Go SFU, so agent code receives
decoded PCM from a track and never touches RTP
([`../07-livekit/01-architecture.md`](../07-livekit/01-architecture.md)). Telephony arrives
through a separate SIP service that bridges RTP to the same room abstraction
([`../07-livekit/05-telephony-sip.md`](../07-livekit/05-telephony-sip.md)). The design choice
worth copying is that the transport is a boundary, not a concern that leaks into agent logic.

**Pipecat** treats the transport as a pluggable input/output pair — WebRTC (Daily), plain
WebSocket, and a Twilio-specific transport that speaks exactly the §2.8 message set including
`clear` and `mark`. Having all three behind one interface is what lets the same agent run on a
browser and on a phone number.

**Vendor streaming APIs are WebSockets by convention** — ASR and TTS providers alike — and per
§2.6 that is defensible, because the hop is server-to-server. Note what you inherit: you must
implement your own sequencing, your own flush semantics, and your own reconnect-with-resume,
because the protocol gives you none of them.

**OpenAI's Realtime API offers both WebSocket and WebRTC**, and the split follows this chapter
exactly: WebRTC for browser clients on the public internet, WebSocket for server-side
integrations ([`04-speech-to-speech.md`](04-speech-to-speech.md)).

**Browsers give you WebRTC and nothing else that is adequate.** `getUserMedia` plus a peer
connection also gets you the audio processing module — echo cancellation, noise suppression,
gain control — which a raw WebSocket client does not have and cannot easily replace
([`../03-turn-taking/05-echo-and-aec.md`](../03-turn-taking/05-echo-and-aec.md)). Choosing a
WebSocket for a browser voice client silently gives up AEC, which is usually a bigger problem
than the packet loss.

---

## 5. At scale

**Packet rate, not bandwidth, is the scaling variable.** At 50 packets/s per direction, 10 000
concurrent calls is $10\,000 \times 50 \times 2 = 1$ million packets/s through your media
plane. Bandwidth is modest — Opus at 40 kbit/s wire in each direction is 800 Mbit/s for the same
10 000 calls — but per-packet cost (syscalls, interrupt handling, SRTP crypto) is what saturates
a media server. DTX removes roughly half of it during silence, which is why it is on by default.

**Egress is cheap; TURN relay is not.** 40 kbit/s each way for 1000 minutes is about 600 MB, so
raw egress per 1000 call-minutes is on the order of cents `[INFERENCE — arithmetic; prices vary
by provider]`. But every session that fails ICE and falls back to TURN relays *both* directions
through your infrastructure and doubles it, and the TURN fallback rate on restrictive corporate
networks is not small ([`02-webrtc-internals.md`](02-webrtc-internals.md)). Budget TURN by
measured fallback rate, not by hope.

**Media cannot sit behind an HTTP load balancer.** A layer-7 load balancer terminates TCP,
inspects HTTP, and knows nothing about UDP ports or ICE candidates. Media servers need direct
addressability and session affinity, which is a deployment constraint that surprises teams the
first time
([`../07-livekit/04-self-hosting-and-scale.md`](../07-livekit/04-self-hosting-and-scale.md)).

**One WebSocket per call is a connection-count problem.** 10 000 concurrent calls means 10 000
open TCP connections per direction of integration — plus one to your ASR vendor and one to your
TTS vendor per call, so possibly 30 000. File-descriptor limits, ephemeral-port exhaustion on
the outbound side, and TLS handshake CPU at churn are all real at that scale, and none of them
appear in testing at ten calls.

**Choose regions by RTT, not by convenience.** Every 20 ms of RTT is 20 ms out of the
conversational budget and, under TCP, an amplifier on loss damage (§2.2). Terminating media
close to the user and doing the model work centrally is usually the right split
([`08-deployment.md`](08-deployment.md)).

---

## 6. Exercises

**E6.1.1** Run the §3 listing. Add a fourth transport, "TCP with a 200 ms application-level
buffer", and report at which loss rate it beats plain RTP on usable frames — and what it costs
in latency.

**E6.1.2** Change the loss model from independent to bursty (two-state Gilbert–Elliott, mean
burst 3 packets) at the same average loss. Report how RTP+FEC's advantage changes, and explain
the mechanism.

**E6.1.3** Compute wire bandwidth for your own deployment: codec, frame size, transport, and
number of concurrent calls. Then recompute with 40 ms frames and state what you gained and what
you lost.

**E6.1.4** Implement the §2.7 binary subprotocol: header pack/unpack, sequence-gap detection,
and `mark`/`clear`. Prove `clear` works by measuring how much already-sent audio is discarded.

**E6.1.5** Take a real Twilio `media` message and verify the §2.4 arithmetic yourself: decode
the payload, count the bytes, and compute the inflation factor for your `streamSid` length.

**E6.1.6** Measure the loss and RTT of the path your service actually uses (a datacentre hop and
a mobile client). Use the §2.2 formula to predict TCP's late rate on each, then decide the
transport with evidence.

**E6.1.7** Disable DTX on a test call and measure the change in packets/s and bytes/s over 60
seconds of realistic conversation. Report the fraction of packets DTX removes.

**E6.1.8** Build the sequence-gap detector for a WebSocket audio stream and run it against a
vendor ASR connection for an hour. Report whether you ever observe a gap — and what that tells
you about §2.6.

---

## 7. Interview drill

> "Our browser voice agent sounds fine in the office and callers on mobile say it cuts out. We
> stream audio over a WebSocket. Where do you start?"

The symptom pattern is the diagnosis. "Fine in the office, broken on mobile" is loss and RTT,
and a WebSocket is TCP, so this is head-of-line blocking. The mechanism is worth stating
precisely rather than gesturing at: TCP delivers in order, so a lost segment stalls delivery of
every frame behind it for at least one round trip, even though those frames are already on the
device. The damage from a single loss is roughly RTT divided by the frame duration, so at a
200 ms mobile RTT one loss ruins ten frames of audio. In the measurement in §2.2, 5% loss at
200 ms RTT left only 66% of frames usable under TCP against 95% for plain RTP and 99.8% for RTP
with Opus FEC — with zero packets lost by TCP, which is exactly why the transport metrics look
clean while the call sounds broken.

The fix is WebRTC on the client leg, and it is worth being explicit that this is not only about
UDP. You also get a jitter buffer that adapts, PLC and in-band FEC, congestion control that
backs off instead of queueing, and — often the larger win — the browser's echo canceller and
noise suppression, which a raw WebSocket client does not have. If the agent has also been
interrupting itself, that is likely the same root cause wearing a different costume.

Before rebuilding anything, confirm the hypothesis cheaply: instrument sequence numbers and
arrival times at the receiver and plot inter-arrival gaps. Head-of-line blocking has a
signature — long gaps followed by bursts of frames arriving together — that is unmistakable and
distinguishes it from an encoder stall, a GC pause, or a slow consumer. Correlate the gaps with
retransmission counts if you can get them.

The senior addition is knowing when *not* to migrate. WebSocket is the right transport for the
server-to-server hops in the same system: at datacentre loss and RTT the same measurement shows
TCP indistinguishable from RTP, which is why every streaming ASR vendor ships a WebSocket API
and nobody complains. So the answer is not "WebSockets are bad", it is "WebSockets are bad
across the lossy leg", and the migration should be scoped to the client edge. The premise worth
challenging is whether "cuts out" means dropouts at all: if callers mean the agent talks over
them, that is barge-in and AEC, and no transport change fixes it.

---

## Sources

- Valin, Vos & Terriberry, "Definition of the Opus Audio Codec", RFC 6716, September 2012 — §2.1.1 bitrate sweet spots, §2.1.4 frame sizes ("20 ms frames are a good choice for most applications"), §2.1.7 in-band FEC ("re-encoded … added to a subsequent packet"), §2.1.9 DTX ("only one frame is encoded every 400 milliseconds"), and the SILK 5 ms / CELT 2.5 ms look-ahead figures in §2.3.
- Schulzrinne et al., "RTP: A Transport Protocol for Real-Time Applications", RFC 3550 — the 12-byte RTP header used in §2.4.
- Twilio, "Media Streams — WebSocket Messages", `https://www.twilio.com/docs/voice/media-streams/websocket-messages`, retrieved 2026-08-22 — the `connected`/`start`/`media`/`dtmf`/`stop`/`mark` message set, `mediaFormat` fixed at `audio/x-mulaw` / 8000 / 1, the `media`/`mark`/`clear` messages a server may send, and the warning against including audio file headers in `media.payload`.
- `pipecat-ai/pipecat` 1.7.0 — `src/pipecat/transports/` for the WebRTC / WebSocket / Twilio transport split referenced in §4.
- `[MEASURED]`: both tables are the output of the §3 listing on Apple M5 / macOS 26.5.2, CPython 3.12, stdlib only. Part A is exact arithmetic over real header sizes and a real Twilio envelope; Part B is a simulation over an independent-loss model with Gaussian jitter — real networks lose in bursts, which makes plain RTP worse and FEC's advantage larger, so the TCP-versus-RTP gap reported here is conservative.
