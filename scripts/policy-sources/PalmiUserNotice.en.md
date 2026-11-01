# Palmi Notice for Privacy and Third-Party AI Services

Version: v26.11  Version date: 2026.11.01

Read this document before configuring a model. Selecting “I have read and agree” means that you understand and acknowledge the data flows, third-party service boundaries, sensitive-information cautions, and user-choice responsibilities described here. It does not mean you have accepted any third-party term that was not shown to you. The official terms of third-party services are the current pages published by those services.

## 1. Purpose and Scope

This document is the Palmi user notice shown before first-time model configuration. It explains likely data flows between the local app, user-selected model services, system permissions, and third-party tools, and asks the user to make an explicit acknowledgement before continuing.

This document is not the privacy policy of any model provider. It does not replace the service terms, privacy policy, developer agreement, data processing agreement, acceptable use policy, model license, or safety rules of any third-party model provider, cloud provider, model aggregator, enterprise gateway, system service, or local deployment.

Palmi is a local-first agent app and model-connection interface. The model you choose, the Base URL you enter, the API key you use, the content you send, and the system permissions or tools you enable will determine whether data leaves your device and who processes it.

## 2. Local Data Processing in the Current Product Design

In the current product design, Palmi does not operate its own centralized server-side database for your chat contents, workspace files, attachments, or API keys. Projects, conversations, workspace files, attachments, run records, caches, and preferences are primarily stored in the app container on your device. Model credentials should be stored in the system Keychain or an equivalent secure credential store.

Local OCR, file preview, workspace reads and writes, embedded Python, local caches, conversation management, and data cleanup usually run on the device. Unless you configure a remote model, remote search, remote file service, cloud sync, sharing/export, or another third-party feature, those materials normally are not sent by Palmi itself to a Palmi-operated remote server.

Device-level systems, iCloud or system backup, crash diagnostics, the App Store, enterprise mobile-device management, network proxies, VPNs, security tools, and user-initiated exports may process data under the rules of Apple, an organization administrator, a network service, or a third party chosen by you. Palmi does not control those system-level or user-selected processes.

## 3. When Data May Leave the Device

When you configure and use a remote model service, model aggregator, cloud-hosted endpoint, enterprise gateway, or custom OpenAI-compatible endpoint, prompts, context, file summaries, images, tool results, model-role configuration, system-instruction fragments, conversation history, error information, and necessary request metadata may be sent to that service.

When you enable web search, web reading, maps, mail, messages, phone, calendar, reminders, contacts, location, camera, photos, speech recognition, notifications, Spotlight, system routing, or other tool capabilities, related data may be processed by the relevant system service, search provider, website, account service, enterprise environment, or network service.

When you import, open, copy, share, export, send, upload, or instruct an agent to perform an external action on a file, the file or its contents may be written to a location you choose, sent to an app, provider, or contact you choose, or enter caches and logs of the relevant system.

Network transmission normally requires connectivity. Network carriers, DNS providers, proxies, VPNs, gateways, firewalls, enterprise security products, or third-party services may process network metadata under their own rules.

## 4. Model Services, OpenAI-Compatible Endpoints, and Responsibility Boundaries

OpenAI-compatible only describes similarity in endpoint shape, authentication, request format, message structure, streaming, or tool-call format. It does not mean OpenAI operates the service, and it does not mean the service has the same security, retention, training, deletion, cross-border transfer, dispute, or legal rules as OpenAI.

Third-party model services, cloud providers, model aggregators, enterprise gateways, and self-hosted services may act as independent controllers, processors, joint controllers, infrastructure providers, or model hosts. Their current policies and account agreements govern how they log, retain inputs and outputs, perform safety review, use data for model training, route data to upstream models, handle deletion requests, or respond to government or regulatory requests.

Palmi cannot verify for you the ownership of an endpoint you enter, the source of an API key, account authority, service region, billing responsibility, retention period, training setting, zero-data-retention configuration, enterprise data-protection terms, or the actual upstream model processor. You should confirm these matters before use.

## 5. Sensitive Content, Enterprise Materials, and Data About Others

You should not submit passwords, API keys, private keys, identity numbers, bank cards, health information, minors’ information, precise location, contacts, chat records, customer data, source-code secrets, trade secrets, unpublished research, NDA-protected content, regulated data, or any material that could harm another person’s rights unless you have sufficient authorization, legal basis, and security review.

If you use Palmi on behalf of a company, school, lab, project team, client, family member, or any other third party, you should confirm that you are authorized to configure model services, send the relevant content, grant system permissions, invoke tools, upload or export files, and comply with that organization’s data classification, confidentiality, compliance, procurement, and security approval requirements.

If you are unsure whether a category of information may be sent to a model or third-party service, do not send it by default. Consider redaction, summarization, anonymization, local processing, internal approval, or an enterprise service that satisfies the applicable compliance requirements.

## 6. Tool Calls, System Permissions, and External Actions

Palmi’s agent features may suggest or trigger file reads, file generation, workspace changes, web searches, access to calendar, reminders, contacts, location, photos, camera, speech, system apps, message drafts, or other system actions. Different tools may require iOS permissions, user confirmation, third-party account authorization, or organization policy approval.

Any action that may affect an external system, another person, account assets, schedules, file state, message sending, purchases, payments, deployments, deletion, or public disclosure should be reviewed by a human before execution. Model outputs may be incomplete, inaccurate, outdated, fabricated, biased, or inconsistent with your intent.

Risk increases significantly if you enable automatic approvals, batch execution, script execution, web automation, system routing, or enterprise tool integrations. Use these capabilities only for trusted tasks and reversible environments.

## 7. Local Data Management, Withdrawal, and Deletion

You can manage local data and third-party account data through in-app data management, system settings, iOS permission settings, Keychain or credential reset, provider consoles, third-party account portals, organization administrators, cloud-provider tickets, or app uninstall.

Clearing Palmi’s local workspace, caches, preferences, or model credentials affects only on-device data or copies kept by Palmi. It does not automatically delete data already sent to third-party model services, search providers, websites, cloud providers, aggregators, enterprise gateways, system services, or other apps. Access, correction, export, deletion, stop-training, memory controls, or log-retention controls on the third-party side must be handled under that provider’s policy and account tools.

Deleting or uninstalling the app may still be affected by system backups, enterprise device management, logs, exported files, shared copies, third-party retention periods, and legal hold obligations.

## 8. AI Output and Professional-Risk Notice

Model output is not legal, medical, financial, investment, tax, engineering-safety, mental-health, employment, immigration, education, or other professional advice. For high-risk or professional scenarios, consult a qualified professional and independently verify the result.

Models may generate incorrect facts, faulty code, wrong citations, misleading security advice, non-executable plans, outdated policies, false links, or inappropriate content. You should carefully decide whether to use, distribute, execute, submit, or rely on model output.

Palmi is a tool and workflow interface. It does not guarantee that any third-party model, endpoint, tool, search source, system service, or user configuration is always available, accurate, secure, compliant, or fit for a particular purpose.

## 9. Common Model-Service Policy Entries

The list below sets out policy entries that may be relevant to Palmi’s current quick entries, retained or common OpenAI-compatible providers, aggregators, and custom model services. Links are public entries or official console entries collected for this document version. Providers may show different terms depending on country or region, account type, enterprise agreement, API product, model, hosting route, and upstream provider. Before use, rely on the provider’s current page.

### Zhipu AI / GLM / Z.ai / BigModel

One of Palmi’s currently selectable quick provider entries; may also appear through a custom OpenAI-compatible endpoint.

- [BigModel / Zhipu Open Platform](https://open.bigmodel.cn/)
- [Z.ai official entry](https://z.ai/)

Before use, review the latest service terms, privacy policy, developer terms, and data processing terms shown in the console or sign-in flow.

### DeepSeek

One of Palmi’s currently selectable quick provider entries; may also be reached through the official API, an aggregator, or a custom endpoint.

- [DeepSeek Privacy Policy](https://cdn.deepseek.com/policies/en-US/deepseek-privacy-policy.html)
- [DeepSeek Terms of Use](https://cdn.deepseek.com/policies/en-US/deepseek-terms-of-use.html)

### Custom OpenAI-compatible endpoint

A user-supplied Base URL, API key, and model name. The actual service may be an official provider, aggregator, cloud host, enterprise gateway, local server, or self-hosted service.

OpenAI-compatible describes an API shape only; it does not mean OpenAI operates the endpoint or that privacy, retention, training, deletion, or transfer rules are the same.

Review the current policy of the endpoint owner, organization gateway, or self-hosted system before sending data.

### OpenAI / ChatGPT

May appear through a custom endpoint, OpenRouter, Azure OpenAI, or another hosted route.

- [OpenAI Privacy Policy](https://openai.com/policies/privacy-policy/)
- [OpenAI Terms of Use](https://openai.com/policies/terms-of-use/)

### Microsoft Azure OpenAI / Azure AI Foundry

May be used through an Azure resource, enterprise account, or custom endpoint.

- [Microsoft Privacy Statement](https://www.microsoft.com/en-us/privacy/privacystatement)
- [Azure OpenAI data, privacy, and security](https://learn.microsoft.com/en-us/azure/foundry/responsible-ai/openai/data-privacy)

### Alibaba Cloud Model Studio / DashScope / Qwen

May appear through Alibaba Cloud Model Studio or DashScope OpenAI-compatible endpoints, custom endpoints, or aggregators.

- [Alibaba Cloud privacy entry](https://www.aliyun.com/legal/privacy)
- [DashScope documentation entry](https://help.aliyun.com/zh/dashscope/)

For enterprise accounts, also review Alibaba Cloud service terms, data processing agreements, and region-specific rules.

### Moonshot AI / Kimi

May appear through the Kimi / Moonshot official API, a custom endpoint, or an aggregator.

- [Moonshot AI Open Platform](https://platform.moonshot.cn/)
- [Kimi official entry](https://kimi.moonshot.cn/)

Use the latest privacy policy, service agreement, and API terms shown on the open platform or sign-in page.

### MiniMax / Hailuo / Talkie

May appear through the MiniMax official API, a custom endpoint, or an aggregator.

- [MiniMax official site](https://www.minimax.io/)
- [MiniMax open platform](https://platform.minimaxi.com/)

Use the privacy policy, service agreement, and API terms displayed in the platform and account console.

### Volcengine Ark / Doubao

May appear through Volcengine Ark OpenAI-compatible endpoints, a custom endpoint, or an aggregator.

- [Volcengine privacy entry](https://www.volcengine.com/docs/6256/64902)
- [Volcengine Ark documentation entry](https://www.volcengine.com/docs/82379)

### Tencent Hunyuan

May appear through Tencent Cloud Hunyuan APIs, a custom endpoint, or an aggregator.

- [Tencent Cloud Privacy Statement](https://cloud.tencent.com/document/product/301/11470)
- [Tencent Cloud Service Agreement entry](https://cloud.tencent.com/document/product/301/1967)

### Baidu Qianfan / ERNIE

May appear through Baidu AI Cloud Qianfan endpoints, a custom endpoint, or an aggregator.

- [Baidu Privacy Center](https://privacy.baidu.com/policy)
- [Baidu AI Cloud Qianfan documentation entry](https://cloud.baidu.com/doc/WENXINWORKSHOP/)

### StepFun

May appear through the StepFun official API, a custom endpoint, or an aggregator.

- [StepFun open platform](https://platform.stepfun.com/)

Use the service agreement, privacy policy, and developer terms shown in the StepFun console.

### ModelScope

May appear as a model hosting or inference service entry.

- [ModelScope official entry](https://modelscope.cn/)

Review the ModelScope service terms, privacy policy, and the relevant model card/license.

### SiliconFlow

May appear as a model aggregation and inference platform.

- [SiliconFlow official entry](https://siliconflow.cn/)

Review its privacy policy, service terms, model-service terms, and upstream model-provider rules.

### OpenRouter

May appear as a global model aggregator; the selected upstream model provider may also process inputs and outputs.

- [OpenRouter Privacy Policy](https://openrouter.ai/privacy)
- [OpenRouter Terms of Service](https://openrouter.ai/terms)

Also review its provider/data pages and the policy of the selected upstream model provider.

### Ollama

Typically used for local or LAN model services. If you connect official cloud or remote hosted services, review those policies separately.

- [Ollama Privacy Policy](https://ollama.com/privacy)
- [Ollama Terms](https://ollama.com/terms)

### LM Studio

Typically used for local desktop or LAN model services. If remote downloads, accounts, sync, or hosted services are enabled, review its policies.

- [LM Studio Privacy](https://lmstudio.ai/privacy)
- [LM Studio Terms](https://lmstudio.ai/terms)

### Anthropic / Claude

One of Palmi’s currently selectable quick provider entries, connected through the native Anthropic Messages API; Claude may also appear through OpenRouter, an enterprise gateway, or a custom endpoint.

- [Anthropic Privacy Policy](https://www.anthropic.com/legal/privacy)
- [Anthropic terms and policies](https://www.anthropic.com/legal)

### Google Gemini / Google AI Studio / Vertex AI

May appear through Google APIs, Vertex AI, an aggregator, or an enterprise gateway.

- [Google Privacy Policy](https://policies.google.com/privacy)
- [Google Cloud Privacy Notice](https://cloud.google.com/terms/cloud-privacy-notice)
- [Google AI / Gemini API additional terms](https://ai.google.dev/terms)

### Mistral AI

May appear through the Mistral official API, an aggregator, or an enterprise gateway.

- [Mistral AI Legal Center](https://legal.mistral.ai/terms)
- [Mistral AI Privacy Policy](https://legal.mistral.ai/terms/privacy-policy)

### Meta / Llama

Usually appears through third-party hosting, a cloud provider, aggregator, local deployment, or enterprise gateway. A public model license is not a hosting-service privacy policy.

- [Meta Privacy Policy](https://www.facebook.com/privacy/policy/)
- [Llama official site](https://www.llama.com/)

Also review the actual host, cloud provider, or local deployer policy.

### xAI / Grok

May appear through the official API, an aggregator, or an enterprise gateway.

- [xAI Privacy Policy](https://x.ai/legal/privacy-policy)
- [xAI Terms of Service](https://x.ai/legal/terms-of-service)

### Cohere

May appear through the Cohere official API, an aggregator, or an enterprise gateway.

- [Cohere Privacy Policy](https://cohere.com/privacy)
- [Cohere Terms of Use](https://cohere.com/terms-of-use)

### Hugging Face / Inference Providers

May appear for model downloads, hosted inference, Spaces, or third-party inference providers.

- [Hugging Face Privacy Policy](https://huggingface.co/privacy)
- [Hugging Face Terms of Service](https://huggingface.co/terms-of-service)

Also review the actual inference provider and the relevant model license.

### Together AI / Fireworks AI / Groq / Replicate / Perplexity / AI21 Labs

These services may appear through custom endpoints, aggregators, SDKs, enterprise gateways, or upstream hosting routes.

- [Together AI Privacy](https://www.together.ai/privacy)
- [Fireworks AI Privacy](https://fireworks.ai/privacy)
- [Groq Privacy Policy](https://groq.com/privacy-policy/)
- [Replicate Privacy](https://replicate.com/privacy)
- [Perplexity Privacy Policy](https://www.perplexity.ai/hub/legal/privacy-policy)
- [AI21 Labs Privacy Policy](https://www.ai21.com/privacy-policy)

### iFlytek Spark / Huawei Cloud Pangu / SenseTime / Baichuan / 01.AI / Xiaomi / Meituan and other providers

May appear through a custom endpoint, cloud marketplace, enterprise gateway, local deployment, or aggregator. Applicable rules vary by account, region, service form, and host.

- [iFlytek open-platform privacy entry](https://www.xfyun.cn/doc/policy/privacy.html)
- [Huawei Cloud privacy entry](https://www.huaweicloud.com/declaration/sa_prp.html)
- [Xiaomi privacy policy entry](https://privacy.mi.com/all/zh_CN/)

For Meituan LongCat, Baichuan, 01.AI, SenseTime, and similar services, use the latest policy shown on the provider’s official site, open platform, or model-service console.

If a service is not listed above, apply the same rule: confirm endpoint ownership, service entity, upstream provider, applicable region, logging and training policy, deletion and export methods, costs, and compliance limits.

## 10. User Acknowledgement

1. I understand that Palmi is a local-first agent app and model-connection interface, and that the current design does not use a Palmi-operated centralized server-side database for chat contents, workspace files, attachments, or API keys.
2. I understand that when I configure or use a third-party model, aggregator, search source, system service, enterprise gateway, local or remote self-hosted endpoint, or other tool, the content I choose to send and necessary metadata may be processed by that service.
3. I understand that third-party data retention, training use, upstream routing, cross-border transfer, deletion requests, account security, costs, and dispute handling are governed by that third party’s current policies and my agreement with it.
4. I will submit personal information, enterprise materials, customer data, files, images, code, or other content only when I have sufficient rights, authority, and compliance basis, and I will use human review in high-risk contexts.
5. If I do not agree with this notice or have not confirmed the policy of the provider I selected, I can stop model configuration or go back and change my choice.

This document is intended for in-product user notice and operational acknowledgement. It is not individualized legal advice for any user, organization, industry, or jurisdiction. Before official release, app-store submission, commercial launch, or use in regulated industries, review by qualified professionals in the relevant jurisdictions is recommended.
