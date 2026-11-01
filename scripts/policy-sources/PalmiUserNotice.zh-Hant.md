# Palmi 使用者知情與第三方 AI 服務提示

版本：v26.11　　版本日期：2026.11.01

請在設定模型前完整閱讀本文件。點選「我已閱讀並同意」僅表示你理解並確認本文件所列的資料流向、第三方服務邊界、敏感資訊注意事項和使用者選擇責任；它不表示你已經同意任何未展示的第三方條款。第三方服務的正式政策以其目前頁面為準。

## 1. 閱讀性質和適用範圍

本文件是 Palmi在首次設定模型前向使用者展示的「使用者知情與第三方 AI 服務提示」。它用於說明本機應用程式、使用者自選模型服務、系統權限和第三方工具之間可能發生的資料流向，並要求使用者在繼續設定模型前作出明確確認。

本文件不是某一家模型廠商的隱私權政策，也不取代任何第三方模型服務商、雲端廠商、模型聚合平台、企業閘道、系統服務或本機部署服務的服務協議、隱私權政策、開發者協議、資料處理協議、可接受使用政策、模型授權或安全規則。

Palmi 是一個本機優先的 Agent 應用程式和模型接入介面。使用者選擇哪個模型、填寫哪個 Base URL、使用哪個 API Key、傳送哪些內容、是否開啟系統權限和工具能力，都會影響資料是否離開本機以及由誰處理。

## 2. 目前產品設計下的本機資料處理

在目前版本設計中，Palmi 不以自有伺服器作為集中式聊天內容、工作區檔案、附件或 API Key 資料庫。專案、對話、工作區檔案、附件、執行紀錄、快取和偏好設定主要儲存在裝置本機的應用程式容器內；模型憑證應儲存於系統鑰匙圈或同等安全的憑證儲存區。

本機 OCR、檔案預覽、工作區讀寫、內嵌 Python、本機快取、對話管理和資料清理等能力通常在裝置本機執行。只要使用者沒有設定遠端模型、遠端搜尋、遠端檔案服務、雲端同步、分享匯出或其他第三方功能，相應內容通常不會因 Palmi 本身而被傳送至 Palmi 營運的遠端伺服器。

裝置系統、iCloud／系統備份、當機診斷、App Store、企業行動裝置管理、網路代理、VPN、安全軟體和使用者主動匯出的檔案，可能依照 Apple、組織管理員、網路服務商或使用者選擇的第三方規則處理資料。Palmi 無法控制這些系統層級或使用者主動選擇的處理。

## 3. 哪些情況下資料可能離開本機

當使用者設定並使用遠端模型服務、模型聚合平台、雲端廠商託管 endpoint、企業閘道或自訂 OpenAI-compatible endpoint 時，傳送給模型的提示詞、上下文、檔案摘要、圖片、工具結果、模型角色設定、系統指令片段、對話歷史、錯誤資訊和必要的請求中繼資料可能被傳送至對應服務。

當使用者啟用網頁搜尋、網頁讀取、地圖、郵件、訊息、電話、行事曆、提醒事項、聯絡人、位置、相機、照片、語音辨識、通知、Spotlight、系統路由或其他工具能力時，相關內容可能由對應系統服務、第三方搜尋來源、網站、帳號服務、企業環境或網路服務處理。

當使用者匯入、開啟、複製、分享、匯出、傳送、上傳或讓 Agent 對檔案執行外部動作時，相應檔案或其中內容可能被寫入使用者選擇的位置、傳給使用者選擇的應用程式、服務商或聯絡人，或進入對應系統的快取和日誌。

請求傳輸通常需要網路連線。電信業者、DNS、代理、VPN、閘道、防火牆、企業安全產品或第三方 SDK／服務可能依照其自身規則處理網路中繼資料。

## 4. 模型服務、OpenAI-compatible endpoint 和責任邊界

OpenAI-compatible 僅說明某個介面在路徑、驗證方式、請求格式、訊息結構、串流回應或工具呼叫形態上與 OpenAI 生態相似。它不表示該服務由 OpenAI 提供，也不表示其安全水準、資料保留、訓練使用、刪除機制、跨境傳輸、爭議解決或適用法律與 OpenAI 相同。

第三方模型服務、雲端廠商、模型聚合平台、企業閘道和自行部署服務可能分別充當獨立的個人資料控制者、受託處理者、共同控制者、基礎設施提供者或模型託管方。它們如何記錄日誌、保留輸入與輸出、用於安全審查、用於模型訓練、轉交上游模型、處理刪除請求或回應監管要求，以其目前有效政策和使用者帳號協議為準。

Palmi 無法代替使用者驗證其填寫的 endpoint 歸屬、API Key 來源、帳號權限、服務區域、帳單責任、資料保留期限、模型訓練設定、零資料保留設定、企業資料保護條款或上游模型的實際處理方。使用者在使用前應自行確認。

## 5. 敏感內容、企業資料和他人資料

使用者不應在沒有充分授權、合法依據和安全評估的情況下，向模型或工具提交密碼、API Key、私密金鑰、身分證號碼、銀行卡、醫療健康資料、未成年人資訊、精確位置、通訊錄、聊天紀錄、客戶資料、原始碼機密、營業秘密、未公開研究、受保密協議保護的內容、受監管資料或任何可能導致他人權益受損的資料。

如果使用者代表公司、學校、實驗室、專案團隊、客戶、家庭成員或其他第三方使用 Palmi，使用者應確認自己有權設定模型服務、傳送相關內容、授予系統權限、呼叫工具、上傳或匯出檔案，並應遵守所在組織的資料分類、保密、合規、採購和安全審查要求。

如果無法確定某類資訊是否可以傳送給模型或第三方服務，應預設不要傳送，或先進行去識別化、摘要、匿名化、本機處理、內部審批，或選擇符合相應合規要求的企業服務。

## 6. 工具呼叫、系統權限和外部動作

Palmi 的 Agent 能力可能建議或觸發讀取檔案、產生檔案、修改工作區、呼叫網頁搜尋、讀取行事曆／提醒事項／聯絡人／位置／照片／相機／語音、開啟系統應用程式、產生訊息草稿或執行其他系統動作。不同工具可能需要 iOS 系統權限、使用者確認、第三方帳號授權或組織政策允許。

任何會影響外部系統、他人、帳號資產、行程安排、檔案狀態、訊息傳送、購買、付款、部署、刪除或公開揭露的動作，使用者都應在執行前進行人工複核。模型輸出可能不完整、不準確、過時、虛構、帶有偏見，或誤解使用者意圖。

如果使用者啟用自動核准、批次執行、腳本執行、網頁自動化、系統路由或企業工具整合，風險會顯著增加。使用者應只對可信任務和可復原的環境啟用此類能力。

## 7. 本機資料管理、撤回和刪除

使用者可以透過應用程式內資料管理、系統設定、iOS 權限管理、鑰匙圈／憑證重設、模型服務商控制台、第三方帳號後台、組織管理員、雲端廠商工單或解除安裝應用程式等方式，管理本機資料和第三方帳號資料。

清理 Palmi 的本機工作區、快取、偏好設定或模型憑證，只影響裝置本機或 Palmi 保存的副本；這不會自動刪除已經傳送至第三方模型服務、搜尋來源、網站、雲端廠商、聚合平台、企業閘道、系統服務或其他應用程式的資料。第三方端資料的存取、更正、匯出、刪除、停止訓練、關閉記憶或關閉日誌保留，應依照對應服務商的政策和帳號工具辦理。

刪除或解除安裝應用程式後，資料仍可能受到系統備份、企業裝置管理、日誌、匯出檔案、共享副本、第三方保留期限和法定保存義務影響。

## 8. AI 輸出和專業風險提示

模型輸出不構成法律、醫療、金融、投資、稅務、工程安全、心理健康、就業、移民、升學教育或其他專業意見。對於高風險或專業情境，使用者應諮詢合格的專業人員並進行獨立驗證。

模型可能產生錯誤事實、錯誤程式碼、錯誤引用、誤導性的安全建議、不可執行的方案、過期政策、虛假連結或不適當內容。使用者應對使用、傳播、執行、提交或依賴模型輸出所產生的後果審慎判斷。

Palmi 是工具和工作流程介面，不保證任何第三方模型、endpoint、工具、搜尋來源、系統服務或使用者設定始終可用、準確、安全、合規或適合特定目的。

## 9. 常見模型服務政策入口

下文列出 Palmi 目前快捷入口、程式中保留或常見的 OpenAI-compatible／聚合／自訂模型服務可能涉及的政策入口。連結為本文件版本日整理的公開入口或官方控制台入口；服務商可能依國家／地區、帳號類型、企業協議、API 產品、模型、託管方式和上游提供者展示不同文本。使用前請以服務商目前頁面為準。

### 智譜 AI / GLM / Z.ai / BigModel

Palmi 目前可選的快捷模型入口之一；也可能由使用者透過自訂 OpenAI-compatible endpoint 接入。

- [智譜開放平台 / BigModel 控制台](https://open.bigmodel.cn/)
- [Z.ai 官方入口](https://z.ai/)

使用前請在控制台或登入頁確認其最新的服務協議、隱私權政策、開發者協議和資料處理條款。

### DeepSeek / 深度求索

Palmi 目前可選的快捷模型入口之一；也可能透過官方 API、聚合平台或自訂 endpoint 接入。

- [DeepSeek Privacy Policy](https://cdn.deepseek.com/policies/en-US/deepseek-privacy-policy.html)
- [DeepSeek Terms of Use](https://cdn.deepseek.com/policies/en-US/deepseek-terms-of-use.html)

### 自訂 OpenAI-compatible endpoint

使用者自行填寫 Base URL、API Key 和模型名稱；服務商可能是官方廠商、聚合平台、雲端廠商、企業閘道、本機服務或個人自行部署的服務。

OpenAI-compatible 只表示介面形態相容，不表示由 OpenAI 提供，也不表示隱私、保留、訓練、刪除、跨境傳輸規則相同。

請在 endpoint 所屬服務商、組織閘道或自行部署的系統中查閱目前有效的政策。

### OpenAI / ChatGPT

可能透過自訂 endpoint、OpenRouter、Azure OpenAI 或其他託管方式出現。

- [OpenAI Privacy Policy](https://openai.com/policies/privacy-policy/)
- [OpenAI Terms of Use](https://openai.com/policies/terms-of-use/)

### Microsoft Azure OpenAI / Azure AI Foundry

可能透過 Azure 資源、企業帳號或自訂 endpoint 接入。

- [Microsoft Privacy Statement](https://www.microsoft.com/en-us/privacy/privacystatement)
- [Azure OpenAI data, privacy, and security](https://learn.microsoft.com/en-us/azure/foundry/responsible-ai/openai/data-privacy)

### 阿里雲百煉 / DashScope / 通義千問 / Qwen

可能透過阿里雲百煉或 DashScope OpenAI-compatible endpoint、自訂 endpoint 或聚合平台出現。

- [阿里雲隱私權政策入口](https://www.aliyun.com/legal/privacy)
- [DashScope / 百煉文件入口](https://help.aliyun.com/zh/dashscope/)

使用企業帳號時，還應查閱阿里雲服務協議、資料處理協議和所選區域的規則。

### Moonshot AI / Kimi

可能透過 Kimi / Moonshot 官方 API、自訂 endpoint 或聚合平台出現。

- [Moonshot AI 開放平台](https://platform.moonshot.cn/)
- [Kimi 官方入口](https://kimi.moonshot.cn/)

請以開放平台或登入頁展示的最新隱私權政策、服務協議和 API 條款為準。

### MiniMax / 海螺 / Talkie

可能透過 MiniMax 官方 API、自訂 endpoint 或聚合平台出現。

- [MiniMax 官方網站](https://www.minimax.io/)
- [MiniMax 開放平台](https://platform.minimaxi.com/)

請以開放平台和帳號後台展示的隱私權政策、服務協議、API 條款為準。

### 火山方舟 / 豆包 / Volcengine Ark

可能透過火山引擎方舟 OpenAI-compatible endpoint、自訂 endpoint 或聚合平台出現。

- [火山引擎隱私權政策入口](https://www.volcengine.com/docs/6256/64902)
- [火山方舟文件入口](https://www.volcengine.com/docs/82379)

### 騰訊混元 / Tencent Hunyuan

可能透過騰訊雲混元 API、自訂 endpoint 或聚合平台出現。

- [騰訊雲隱私保護聲明](https://cloud.tencent.com/document/product/301/11470)
- [騰訊雲服務協議入口](https://cloud.tencent.com/document/product/301/1967)

### 百度智慧雲千帆 / 文心 / ERNIE

可能透過百度智慧雲千帆 endpoint、自訂 endpoint 或聚合平台出現。

- [百度隱私保護平台](https://privacy.baidu.com/policy)
- [百度智慧雲千帆文件入口](https://cloud.baidu.com/doc/WENXINWORKSHOP/)

### 階躍星辰 / StepFun

可能透過 StepFun 官方 API、自訂 endpoint 或聚合平台出現。

- [StepFun 開放平台](https://platform.stepfun.com/)

請以 StepFun 控制台展示的服務協議、隱私權政策和開發者條款為準。

### ModelScope / 魔搭社群

可能作為模型託管或推論服務入口出現。

- [ModelScope 官方入口](https://modelscope.cn/)

請閱讀 ModelScope 服務協議、隱私權政策和具體的模型卡／授權條款。

### SiliconFlow / 矽基流動

可能作為中國大陸的模型聚合與推論平台出現。

- [SiliconFlow 官方入口](https://siliconflow.cn/)

請閱讀其隱私權政策、服務協議、模型服務條款和上游模型提供者的規則。

### OpenRouter

可能作為全球模型聚合平台出現；上游模型提供者也可能獨立處理輸入和輸出。

- [OpenRouter Privacy Policy](https://openrouter.ai/privacy)
- [OpenRouter Terms of Service](https://openrouter.ai/terms)

還應閱讀其 provider／data 頁面和所選上游模型廠商的政策。

### Ollama

主要用於本機或區域網路模型服務；如果連接官方雲端或遠端託管服務，應另行閱讀對應政策。

- [Ollama Privacy Policy](https://ollama.com/privacy)
- [Ollama Terms](https://ollama.com/terms)

### LM Studio

主要用於本機桌面或區域網路模型服務；若啟用遠端下載、帳號、同步或託管服務，應查閱其政策。

- [LM Studio Privacy](https://lmstudio.ai/privacy)
- [LM Studio Terms](https://lmstudio.ai/terms)

### Anthropic / Claude

Palmi 目前可選的快捷模型入口之一，透過 Anthropic 原生 Messages 介面接入；Claude 也可能透過 OpenRouter、企業閘道或自訂 endpoint 出現。

- [Anthropic Privacy Policy](https://www.anthropic.com/legal/privacy)
- [Anthropic Terms and policies](https://www.anthropic.com/legal)

### Google Gemini / Google AI Studio / Vertex AI

可能透過 Google 官方 API、Vertex AI、聚合平台或企業閘道出現。

- [Google Privacy Policy](https://policies.google.com/privacy)
- [Google Cloud Privacy Notice](https://cloud.google.com/terms/cloud-privacy-notice)
- [Google AI / Gemini API additional terms](https://ai.google.dev/terms)

### Mistral AI

可能透過 Mistral 官方 API、聚合平台或企業閘道出現。

- [Mistral AI Legal Center](https://legal.mistral.ai/terms)
- [Mistral AI Privacy Policy](https://legal.mistral.ai/terms/privacy-policy)

### Meta / Llama

通常透過第三方託管、雲端廠商、聚合平台、本機部署或企業閘道出現；Meta 公開的模型授權不等同於託管服務的隱私權政策。

- [Meta Privacy Policy](https://www.facebook.com/privacy/policy/)
- [Llama official site](https://www.llama.com/)

還應閱讀實際託管方、雲端廠商或本機部署者的政策。

### xAI / Grok

可能透過官方 API、聚合平台或企業閘道出現。

- [xAI Privacy Policy](https://x.ai/legal/privacy-policy)
- [xAI Terms of Service](https://x.ai/legal/terms-of-service)

### Cohere

可能透過 Cohere 官方 API、聚合平台或企業閘道出現。

- [Cohere Privacy Policy](https://cohere.com/privacy)
- [Cohere Terms of Use](https://cohere.com/terms-of-use)

### Hugging Face / Inference Providers

可能作為模型下載、託管、推論、Spaces 或第三方 inference provider 的入口出現。

- [Hugging Face Privacy Policy](https://huggingface.co/privacy)
- [Hugging Face Terms of Service](https://huggingface.co/terms-of-service)

還應閱讀實際的 inference provider 和具體模型的授權條款。

### Together AI / Fireworks AI / Groq / Replicate / Perplexity / AI21 Labs

這些服務可能透過自訂 endpoint、聚合平台、SDK、企業閘道或上游託管方出現。

- [Together AI Privacy](https://www.together.ai/privacy)
- [Fireworks AI Privacy](https://fireworks.ai/privacy)
- [Groq Privacy Policy](https://groq.com/privacy-policy/)
- [Replicate Privacy](https://replicate.com/privacy)
- [Perplexity Privacy Policy](https://www.perplexity.ai/hub/legal/privacy-policy)
- [AI21 Labs Privacy Policy](https://www.ai21.com/privacy-policy)

### 訊飛星火 / 華為雲盤古 / 商湯日日新 / 百川智能 / 零一萬物 / 小米 / 美團等其他模型或託管入口

可能透過自訂 endpoint、雲端市集、企業閘道、本機部署或聚合平台出現；具體政策隨帳號、地區、服務形態和託管主體而變化。

- [訊飛開放平台隱私權政策入口](https://www.xfyun.cn/doc/policy/privacy.html)
- [華為雲隱私保護入口](https://www.huaweicloud.com/declaration/sa_prp.html)
- [小米隱私權政策入口](https://privacy.mi.com/all/zh_CN/)

對於美團 LongCat、百川、零一萬物、商湯等，請以其官網、開放平台或模型服務後台展示的最新政策為準。

如果某個服務未列入上文，仍應依照同樣原則處理：確認 endpoint 歸屬、服務主體、上游提供者、適用區域、日誌與訓練政策、刪除與匯出方式、費用和合規限制。

## 10. 使用者確認

1. 我理解 Palmi 是本機優先的 Agent 應用程式和模型接入介面，目前不以自有伺服器作為集中式聊天內容、工作區檔案、附件或 API Key 資料庫。
2. 我理解當我設定或使用第三方模型、聚合平台、搜尋來源、系統服務、企業閘道、本機／遠端自行部署的 endpoint 或其他工具時，我選擇傳送的內容和必要的中繼資料可能由對應服務處理。
3. 我理解第三方服務的資料保留、訓練使用、上游轉送、跨境傳輸、刪除請求、帳號安全、費用和爭議處理，以該第三方目前有效的政策和我與其之間的協議為準。
4. 我將只在具備充分權利、授權和合規依據的情況下提交個人資料、企業資料、客戶資料、檔案、圖片、程式碼或其他內容，並在高風險情境中進行人工複核。
5. 如果我不同意本提示或尚未確認所選服務商的政策，我可以停止設定模型或返回修改選擇。

本文件用於產品內的使用者知情和操作確認。它不是針對任何使用者、組織、產業或法域的個別法律意見。正式發布、上架、商用或面向受監管產業使用前，建議由具備相應法域經驗的專業人士審閱。
