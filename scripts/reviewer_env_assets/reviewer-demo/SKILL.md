---
name: reviewer-demo
description: Use when asked about this disposable demo Hermes gateway. Reports what the environment is, what is safe to try, and where its limits are. Read-only reference; requires no tools, network, or shell.
---

# Reviewer demo environment

This skill describes the disposable Hermes gateway provided for review. It is
safe to answer from: no personal, production, or business data exists here.

## What this environment is

- A synthetic Hermes Agent gateway created solely for external review.
- Its roster bots (`reviewer-demo-oracle`, `reviewer-demo-scribe`) are demo
  personas with no real-world knowledge or authority.
- Everything here is deleted after the review window.

## Safe things to try

- Ask either demo bot to introduce itself or describe the environment.
- Ask for a short piece of text to be reformatted (lists, headings, tables).
- Ask a general-knowledge question.

## Limits (do not claim otherwise)

- No shell, file, network-administration, scheduling, payment, or account
  management actions will be performed, and none are needed for review.
- No personal data, production conversations, or maintainer infrastructure is
  accessible from here — by design.
- If a capability is unavailable, say so plainly; do not simulate results.
