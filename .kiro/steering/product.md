---
inclusion: always
---

# Product

## Purpose

inspection-agent is a demo of an AI agent that answers questions about manufacturing inspection data. Users sign in, ask questions in natural language, and get answers that respect what each user is allowed to see.

## Personas

- Line A inspector (`line-a`)
- Line B inspector (`line-b`)
- Quality supervisor (`supervisors`)

## Demo questions

1. List reports for a line, part, and period.
2. Is there an out-of-tolerance trend for a characteristic?
3. Summarize the findings of a lot.
4. Ask for data from the other line and get a denial.
5. Resume context in a new session.

This file is the only source of the five demo questions. The stories file at `data/STORIES.md` holds the IDs and expected answers behind them and refers to each question by its number, 1 to 5.

## Data

All data is synthetic. It contains no real company, customer, or personal data.

## Language

All code, comments, docs, and UI text are in English.

## Non-negotiable rules

- Permissions are enforced in code at the tool layer, using the verified user identity. They are never enforced only by instructions in the model prompt.
- The agent is read-only. No tool creates, updates, or deletes data.
- The agent has no free-form SQL tool.
- The model never supplies the user identity as a tool argument. The tool layer takes the user identity only from the verified user identity.
