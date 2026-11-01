# Third-Party AI Service Data Notice

Version: v26.11  Version date: 2026.11.01

Palmi is a local-first AI tool. It does not operate a cloud model server that receives, stores, or analyzes your chats, attachments, or tool results, and it does not independently collect and upload this information for AI processing when you have not taken an action or granted the relevant permission. Only after you configure a model in the next step, initiate an AI request, and choose the relevant content does the app send the content necessary to perform that request to the third-party AI model service you personally select.

## 1. Data That May Be Sent

1. Messages, prompts, and instructions you actively enter, together with prior messages, conversation context, and task state that the model needs to understand and complete the current request; merely opening the app, remaining on a screen, or moving the app to the background does not by itself upload unrelated chats;
2. Images, documents, and other files you expressly add to the current task, including extracted text, OCR results, file format information, or necessary summaries used to help the model understand those attachments; other local files that you do not add to the request are not sent for this reason;
3. Calendar, reminder, contact, location, photo, or other tool results included in the current task after you separately grant the applicable iOS permission and expressly invoke the tool; granting a system permission is not itself consent to transmit the data, and only results actually used by the current AI request may be sent;
4. System instructions, tool definitions and results, model identifiers, generation parameters, and technical information needed to organize, complete, or recover the current request; this information is used to enable the third-party model to process the task you initiated correctly.

## 2. Recipients

The recipient is the third-party AI model service and API endpoint operator that you personally select or enter and confirm in the next step, not Palmi. The app does not preselect, recommend, or imply a particular service in this notice, and it does not display a configuration that you have not yet completed. After configuration, content included in an AI request you initiate is transmitted over the network to an interface controlled by that service operator. The specific legal operator, server region, and actual data processor depend on the service and terms you ultimately choose. If you cannot verify or do not trust that service’s identity, privacy policy, or data-handling rules, do not complete its configuration or send content to it.

## 3. Purpose

The content is sent only to process requests you actively initiate, including generating model responses, understanding images or files you select, performing Agent tasks you request, and maintaining the context necessary to complete that request. The third-party service may log, review, retain, route to upstream processors, or delete the data under its own privacy policy, terms, and account settings. Palmi cannot determine that third party’s retention period, training use, cross-border processing, or deletion practices. After transmission, requests to access, correct, export, or delete the data must be made through the channels provided by that service operator.

## 4. Local Processing Boundary

Palmi does not operate its own cloud model server for relaying, receiving, or centrally storing the AI-request content described above. Under the current architecture, model requests travel from your device to the third-party endpoint you configure. The app may store workspaces, conversations, and settings locally as required by features you use, but merely opening the app does not cause it to independently collect and upload unrelated personal information. iOS permissions for contacts, calendars, photos, location, and similar data are requested separately by the system when a feature is used; the permission under this notice applies only to sending content you expressly include in an AI task to the third-party model service selected afterward.
