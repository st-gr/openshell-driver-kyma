# Image-generation prompts for the docs diagrams

The Mermaid diagrams at the top of
[`tutorial-anthropic-direct.md`](tutorial-anthropic-direct.md) and
[`walkthrough-claude-files.md`](walkthrough-claude-files.md) render
natively on GitHub and deterministically via
[mermaid.live](https://mermaid.live) or
`npx -y @mermaid-js/mermaid-cli -i <file>.md -o out.svg`. Use those
whenever fidelity matters — they never mislabel a box.

This file is for the other case: producing a **poster-quality image**
of either diagram with an image-generation LLM (GPT-image, Gemini
image generation, and similar). Image models draw prettier diagrams
than Mermaid but are *lossy with small text and topology* — they
hallucinate labels and merge boxes unless the prompt pins both down.
The recipes below are ordered by what most improves fidelity.

Universal rules, both diagrams:

1. **Paste the Mermaid source into the prompt and declare it the
   authoritative spec.** This is the single highest-leverage
   instruction. Copy the fenced `mermaid` block verbatim from the top
   of the target doc.
2. **Proofread every label after generation.** Image models silently
   typo long tokens like `gatewayUpstreamEgress` and
   `inference.local`. Ask for a targeted regeneration naming only the
   wrong labels ("regenerate; fix ONLY these labels: …"), not a fresh
   prompt. Expect 2–3 rounds.
3. **Bail out early.** If more than ~5 labels are wrong per round,
   render the SVG deterministically instead and restyle that.

---

## Prompt A — tutorial flowchart (`tutorial-anthropic-direct.md`)

> Render the following Mermaid flowchart as a clean, flat-vector
> technical flow diagram. The Mermaid source is the authoritative
> specification: reproduce every node, every grouping, every arrow,
> and every text label VERBATIM. Do not invent, merge, drop, or rename
> components. No decorative icons that could be mistaken for
> components.
>
> ```
> <paste the mermaid block from the top of tutorial-anthropic-direct.md>
> ```
>
> Layout: top-to-bottom, a single main spine of seven numbered stages.
> Four grouped containers along the spine: "1 — Cluster bootstrap"
> (three side-by-side boxes), "2 — Values overlay" (contains a decision
> diamond with two outcomes), "3 — helm install chart 0.1.2" (two
> boxes), and "6 — run Claude in a sandbox" (contains the probe
> decision diamond, its two outcomes, the run box, and the data-path
> box).
>
> Visual semantics: solid arrows are the setup flow; the dashed arrow
> from the 503 box back to the probe diamond is a retry loop labelled
> "fix values, retest"; the dashed arrow from the hook Job to the
> Secret is labelled "reads key"; the double-line connection from the
> run box to the data-path box marks the runtime inference path. Color
> coding: red fill for the two failure/trap boxes ("in-cluster /
> RFC1918…" and "HTTP 503…"), green fill for "HTTP 200 — pipeline
> works", blue fill for the data-path box. Everything else neutral.
>
> Style: flat vector, white background, sans-serif labels, high
> contrast, generous whitespace, portrait orientation, no gradients,
> no 3D, no photorealism, no watermark. All label text must be sharply
> legible at 100% zoom.
>
> Before drawing, list the components you will draw and their
> containment, so mismatches can be caught early.

## Prompt B — walkthrough sequence diagram (`walkthrough-claude-files.md`)

> Render the following Mermaid sequence diagram as a clean, flat-vector
> swimlane interaction diagram. The Mermaid source is the authoritative
> specification: keep all six participants in the given left-to-right
> order, keep every message arrow in the given top-to-bottom order with
> its EXACT label text and its autonumber (1–13), and keep the
> wide note spanning the first four lanes. Do not invent, merge, drop,
> or reorder anything.
>
> ```
> <paste the mermaid block from the top of walkthrough-claude-files.md>
> ```
>
> Layout: six vertical lifelines, left to right: "Operator host"
> (drawn as a person/actor), "gateway :8080", "kyma driver",
> "agent-sandbox controller", "sandbox pod (supervisor + claude)",
> "upstream (Anthropic API or bedrock-bridge to SAP AI Core)". A
> horizontal note bar under the participant headers spanning lanes 1–4
> with the one-time-setup text. Then thirteen numbered horizontal
> message arrows in source order.
>
> Visual semantics: solid arrowheads for requests, open/dashed arrows
> for the two reply messages ("schedule pod, sideload supervisor,
> phase Ready" and "completion - claude writes /sandbox/summary.md").
> The self-arrow on the sandbox-pod lane ("L7 router strips
> placeholder x-api-key") must loop back to its own lifeline. Highlight
> the three-message inference core (GetInferenceBundle, POST
> /v1/messages, completion) with a subtle background band across the
> lanes.
>
> Style: flat vector, white background, sans-serif labels, high
> contrast, 16:9 landscape, no gradients, no 3D, no photorealism, no
> watermark. Message labels must be sharply legible at 100% zoom;
> number badges on every arrow.
>
> Before drawing, list the six participants and the thirteen messages
> in order, so mismatches can be caught early.
