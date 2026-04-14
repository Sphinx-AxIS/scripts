# Collection of PowerShell scripts.

## Powershell/AI

## Codex Usage Monitor (PowerShell)

A lightweight PowerShell script that parses local Codex session logs and provides real-time insight into **token usage, context consumption, and burn rate**.

This helps you understand when you're approaching limits and avoid hitting context exhaustion mid-session.

---

## 🔍 What This Script Does

The script reads your local Codex `.jsonl` session files and outputs:

### 📊 Usage Metrics
- Total tokens used (input, cached, output, reasoning)
- Last request token usage
- Effective new input (excluding cached tokens)

### 🧠 Context Awareness
- Model context window size
- Current context utilization (%)
- Remaining available tokens

### 🔥 Burn Rate Analysis
- Average tokens per request (last N events)
- Peak tokens per request
- Estimated remaining turns based on:
  - Average usage
  - Peak usage

### ⏱️ Rate Limit Tracking
- Primary and secondary rate limits
- Time until reset (human-readable)
- Usage percentages

### ⚠️ Intelligent Warnings
- Detects when you're:
  - Near context exhaustion
  - Sending large ("hot") requests
  - At risk of exceeding limits

---

## 🧰 Why This Is Useful

Codex usage inside VS Code can hit limits in ways that aren’t obvious:

- Context window fills up silently
- Large prompts consume tokens quickly
- Rate limits are not always visible

This script gives you a **clear operational view** so you can:

- Avoid hitting context limits mid-task
- Decide when to start a new session
- Optimize prompt size and workflow

---

## 📁 How It Works

The script reads from:

```
$HOME\.codex\sessions\
```

It automatically selects the **most recent `.jsonl` session file**, unless you specify one manually.

---

## 🚀 Usage

### Run with latest session
```powershell
.\Get-CODEXUsage.ps1
```

### Run with a specific session file
```powershell
.\Get-CODEXUsage.ps1 -SessionFile "C:\path\to\session.jsonl"
```

### Adjust averaging window
```powershell
.\Get-CODEXUsage.ps1 -RecentEventsForAverage 10
```

---

## 📈 Example Output

```
Context Window
--------------
Model context window : 258,400
Total tokens in ctx  : 208,871
Context used         : 80.8%

Recent Burn Rate
----------------
Average last 5 req : 35,398
Peak last 5 req    : 54,678

Remaining ctx tokens : 49,529
Turns left @ avg burn: 1
Turns left @ peak burn: 0
```

---

## 🧠 Key Concepts

### Context Window
The maximum number of tokens the model can consider in a session.

> When this fills up, responses degrade or fail.

---

### Cached Tokens
Tokens reused from previous context (cheaper, but still count toward context).

---

### Effective Input
```
input_tokens - cached_input_tokens
```

This shows how much **new information** you're actually adding.

---

### Burn Rate
- **Average** → typical usage
- **Peak** → worst-case usage

Used to estimate how many requests you have left before hitting limits.

---

## ⚠️ Interpreting "Heat"

| Heat | Meaning |
|------|--------|
| COOL | Low usage |
| WARM | Moderate usage |
| HOT  | High usage / near limits |

---

## 🚨 When to Start a New Session

You should strongly consider resetting when:

- Context usage > **75–80%**
- Turns left @ avg burn ≤ **1**
- Turns left @ peak burn = **0**

---

## 🔧 Requirements

- PowerShell 5+ or PowerShell Core
- Codex (VS Code extension)
- Local Codex session logs (`.codex\sessions`)

---

## 💡 Tips

- Large prompts and pasted code drive token usage up quickly
- Cached tokens reduce cost but still consume context
- Long sessions = higher risk of hitting limits

---

## 📌 Future Improvements (Ideas)

- Live updating dashboard (refresh every few seconds)
- Color-coded output (green/yellow/red thresholds)
- Historical trend tracking
- Export to CSV / JSON for analysis

---

## 🧾 License

MIT (or whatever you choose)
