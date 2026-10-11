---
name: web-operator
description: Use Palmi's in-app browser in Pro mode for tasks that need real web interaction, such as search boxes, filters, pagination, signed-in pages, ordering flows, and dynamically loaded content.
---

# Web Operator

## 1. Understand the request before touching the browser

- Work out exactly what result the user wants and every constraint that shapes it: location, budget, time, quantity, preferences, accounts, and what must not happen.
- If a missing detail would change which site you use or what you would do there, ask the user first. Do not set out on a guess.
- Decide what "done" looks like, so you know when to stop and what to report.

## 2. Find the right entry point first

- Identify the most reliable site for the task: the official service or a well-known platform the user is likely to use. Prefer its mobile site.
- Never guess or reconstruct URLs from memory. Confirm the address with web_search, or read candidate pages with fetch, then open the confirmed URL in the browser.
- If the information only needs reading and no interaction, fetch/web_search is enough; do not open the browser.

## 3. Operate in a tight loop

1. open the confirmed URL and read the returned observation: address, title, visible text, and interactive elements.
2. Take one action that moves the task forward.
3. Judge the result only from the new observation the action returns. Never assume a click, input, or submission succeeded.
4. Repeat until the goal is reached. Use observe(scope=text, start, count) to read a long page in pages, following next_start.

- Act through e refs together with the latest observation_id. A new observation invalidates old refs; on a stale error, observe again.
- When the structure does not show the target or the visual layout matters, use look and act on the e refs in its answer. Coordinate clicks are a last resort. Without a multimodal model, keep working from observe.
- If the page is not what you expected (wrong site, region, or language), go back to step 2 instead of pushing through.

## 4. Tabs

- The browser is shared with the user across the app. Your conversation has a current tab; open reuses it, and new_tab=true opens another when you need to compare pages side by side.
- Use tabs to see what is open and pass tab to work on a specific one, including a page the user already opened for you.
- Leave result pages open for the user. Close a tab only when the user asks or it is clearly scratch work you created.

## 5. Distractions

Decline non-essential cookie and privacy choices, or close the banner with the minimum consent. Close ads and promotional pop-ups, then observe the target content again.

## 6. User handoff and approval

- Proceed normally first. Only when a page actually requires sign-in or a CAPTCHA, or a password or payment field must be filled, call handoff. It shows the browser full screen and waits until the user taps Done, then returns a fresh observation so you continue in the same turn.
- Never try to bypass a CAPTCHA, and never ask the user for a password to type it yourself.
- Before ordering, paying, sending, posting, submitting personal information, or deleting anything, tell the user exactly what you are about to do and wait for explicit approval. Approval covers only the action and content you described.

## 7. Interruptions

On requires_foreground, pause browser steps, finish any work that does not need the browser, and tell the user they can return to Palmi to continue. After an interrupted interaction, observe the current state first; never blindly repeat an action whose outcome is unknown.

## 8. Report

Report the result and the key details (prices, options, times, links), state which page they came from, and keep the page open so the user can check it.
