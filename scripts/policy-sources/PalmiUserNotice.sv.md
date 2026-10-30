# Palmis information om integritet och AI-tjänster från tredje part

Dokument att läsa och bekräfta innan en modell konfigureras för första gången

Version: v26.7  
Versionsdatum: 2026.07.01  
Målgrupp: användare av mobilappen Palmi / PalmiAgent

**Viktigt:** Läs dokumentet innan du konfigurerar en modell. Genom att välja ”Jag har läst och godkänner” bekräftar du att du förstår och är införstådd med de dataflöden, gränser för tredjepartstjänster, försiktighetsåtgärder för känslig information och ansvar vid användarval som beskrivs här. Det innebär inte att du har godkänt tredjepartsvillkor som inte har visats för dig. De officiella villkoren för tredjepartstjänster är de aktuella sidor som tjänsterna publicerar.

## 1. Syfte och omfattning

Detta dokument är Palmis (PalmiAgents) användarinformation som visas innan en modell konfigureras för första gången. Det förklarar möjliga dataflöden mellan den lokala appen, modelltjänster som användaren väljer, systembehörigheter och tredjepartsverktyg, och ber användaren att uttryckligen bekräfta informationen innan hen fortsätter.

Dokumentet är inte någon modellleverantörs integritetspolicy. Det ersätter inte användarvillkor, integritetspolicy, utvecklaravtal, personuppgiftsbiträdesavtal, policy för godtagbar användning, modelllicens eller säkerhetsregler för någon tredjepartsmodellleverantör, molnleverantör, modellaggregator, företagsgateway, systemtjänst eller lokal driftsättning.

Palmi är en agentapp som i första hand arbetar lokalt och ett gränssnitt för modellanslutning. Modellen du väljer, bas-URL:en du anger, API-nyckeln du använder, innehållet du skickar och de systembehörigheter eller verktyg du aktiverar avgör om data lämnar din enhet och vem som behandlar dem.

## 2. Lokal databehandling i den nuvarande produktutformningen

I den nuvarande produktutformningen driver Palmi ingen egen centraliserad serverdatabas för dina chattinnehåll, arbetsytefiler, bilagor eller API-nycklar. Projekt, konversationer, arbetsytefiler, bilagor, körningsposter, cache och inställningar lagras främst i appens behållare på din enhet. Inloggningsuppgifter för modeller bör lagras i systemets Nyckelring eller ett likvärdigt säkert lagringsutrymme för inloggningsuppgifter.

Lokal OCR, filförhandsvisning, läsning och skrivning på arbetsytan, inbäddad Python, lokal cache, konversationshantering och datarensning körs vanligtvis på enheten. Om du inte konfigurerar en fjärrmodell, fjärrsökning, fjärrfiltjänst, molnsynkronisering, delning/export eller någon annan tredjepartsfunktion skickas materialet normalt inte av Palmi självt till en fjärrserver som Palmi driver.

System på enhetsnivå, iCloud eller systemsäkerhetskopiering, kraschdiagnostik, App Store, företagsadministration av mobila enheter, nätverksproxyer, VPN:er, säkerhetsverktyg och exporter som användaren startar kan behandla data enligt regler från Apple, en organisationsadministratör, en nätverkstjänst eller en tredje part som du väljer. Palmi kontrollerar inte dessa processer på systemnivå eller processer som användaren väljer.

## 3. När data kan lämna enheten

När du konfigurerar och använder en fjärrmodelltjänst, modellaggregator, molnbaserad ändpunkt, företagsgateway eller anpassad OpenAI-kompatibel ändpunkt kan promptar, kontext, filsammanfattningar, bilder, verktygsresultat, modellrollskonfiguration, fragment av systeminstruktioner, konversationshistorik, felinformation och nödvändiga metadata för begäran skickas till tjänsten.

När du aktiverar webbsökning, webbläsning, kartor, e-post, meddelanden, telefon, kalender, påminnelser, kontakter, plats, kamera, bilder, taligenkänning, notiser, Spotlight, systemdirigering eller andra verktygsfunktioner kan tillhörande data behandlas av relevant systemtjänst, sökleverantör, webbplats, kontotjänst, företagsmiljö eller nätverkstjänst.

När du importerar, öppnar, kopierar, delar, exporterar, skickar eller laddar upp en fil, eller instruerar en agent att utföra en extern åtgärd på en fil, kan filen eller dess innehåll skrivas till en plats du väljer, skickas till en app, leverantör eller kontakt du väljer eller hamna i det relevanta systemets cache och loggar.

Nätverksöverföring kräver normalt anslutning. Nätoperatörer, DNS-leverantörer, proxyer, VPN:er, gateways, brandväggar, företagsprodukter för säkerhet eller tredjepartstjänster kan behandla nätverksmetadata enligt sina egna regler.

## 4. Modelltjänster, OpenAI-kompatibla ändpunkter och ansvarsgränser

OpenAI-kompatibel beskriver endast likheter i ändpunktsutformning, autentisering, begäransformat, meddelandestruktur, strömning eller verktygsanropsformat. Det betyder inte att OpenAI driver tjänsten, och det betyder inte att tjänsten har samma regler för säkerhet, lagring, träning, radering, gränsöverskridande överföring, tvister eller juridiska frågor som OpenAI.

Tredjepartsmodelltjänster, molnleverantörer, modellaggregatorer, företagsgateways och tjänster med egen drift kan fungera som självständiga personuppgiftsansvariga, personuppgiftsbiträden, gemensamt personuppgiftsansvariga, infrastrukturleverantörer eller modellvärdar. Deras aktuella policyer och kontoavtal styr hur de loggar, behåller in- och utdata, utför säkerhetsgranskning, använder data för modellträning, dirigerar data till uppströmsmodeller, hanterar begäranden om radering eller svarar på begäranden från myndigheter eller tillsynsorgan.

Palmi kan inte åt dig verifiera ägandet av en ändpunkt du anger, en API-nyckels ursprung, kontobehörighet, tjänsteregion, debiteringsansvar, lagringstid, träningsinställning, konfiguration utan datalagring, företagsvillkor för dataskydd eller den faktiska uppströmsbehandlaren för modellen. Du bör bekräfta dessa saker före användning.

## 5. Känsligt innehåll, företagsmaterial och data om andra

Du bör inte skicka lösenord, API-nycklar, privata nycklar, identitetsnummer, bankkortsuppgifter, hälsoinformation, information om minderåriga, exakt plats, kontakter, chattposter, kunddata, hemligheter i källkod, affärshemligheter, opublicerad forskning, innehåll som omfattas av sekretessavtal, reglerade data eller material som kan skada någon annans rättigheter om du inte har tillräcklig behörighet, rättslig grund och säkerhetsgranskning.

Om du använder Palmi för ett företag, en skola, ett laboratorium, en projektgrupp, en kund, en familjemedlem eller någon annan tredje part bör du bekräfta att du har rätt att konfigurera modelltjänster, skicka relevant innehåll, ge systembehörigheter, anropa verktyg, ladda upp eller exportera filer och uppfylla organisationens krav på dataklassificering, sekretess, regelefterlevnad, inköp och säkerhetsgodkännande.

Om du är osäker på om en viss typ av information får skickas till en modell eller tredjepartstjänst ska du som utgångspunkt inte skicka den. Överväg maskering, sammanfattning, anonymisering, lokal behandling, internt godkännande eller en företagstjänst som uppfyller tillämpliga krav på regelefterlevnad.

## 6. Verktygsanrop, systembehörigheter och externa åtgärder

Palmis agentfunktioner kan föreslå eller utlösa filläsning, filgenerering, ändringar på arbetsytan, webbsökningar, åtkomst till kalender, påminnelser, kontakter, plats, bilder, kamera, tal, systemappar, meddelandeutkast eller andra systemåtgärder. Olika verktyg kan kräva iOS-behörigheter, användarbekräftelse, tredjepartsauktorisering av konto eller godkännande enligt organisationens policy.

Varje åtgärd som kan påverka ett externt system, en annan person, kontotillgångar, scheman, filtillstånd, meddelandesändning, köp, betalningar, driftsättningar, radering eller offentliggörande bör granskas av en människa före körning. Modellutdata kan vara ofullständiga, felaktiga, inaktuella, fabricerade, partiska eller oförenliga med din avsikt.

Risken ökar avsevärt om du aktiverar automatiska godkännanden, batchkörning, skriptkörning, webbautomatisering, systemdirigering eller integrationer med företagsverktyg. Använd dessa funktioner endast för betrodda uppgifter och i miljöer där ändringar kan återställas.

## 7. Lokal datahantering, återkallande och radering

Du kan hantera lokala data och tredjepartskontodata genom datahanteringen i appen, systeminställningar, iOS-behörighetsinställningar, återställning av Nyckelring eller inloggningsuppgifter, leverantörskonsoler, tredjepartsportaler för konton, organisationsadministratörer, supportärenden hos molnleverantörer eller avinstallation av appen.

Rensning av Palmis lokala arbetsyta, cache, inställningar eller modelluppgifter påverkar endast data på enheten eller kopior som Palmi behåller. Det raderar inte automatiskt data som redan har skickats till tredjepartsmodelltjänster, sökleverantörer, webbplatser, molnleverantörer, aggregatorer, företagsgateways, systemtjänster eller andra appar. Åtkomst, rättelse, export, radering, stopp för träning, minnesinställningar eller inställningar för logglagring hos tredje part måste hanteras enligt den leverantörens policy och kontoverktyg.

Radering eller avinstallation av appen kan fortfarande påverkas av systemsäkerhetskopior, företagsadministration av enheter, loggar, exporterade filer, delade kopior, tredje parters lagringstider och rättsliga skyldigheter att bevara uppgifter.

## 8. Information om AI-utdata och yrkesrelaterade risker

Modellutdata är inte juridisk, medicinsk, finansiell, investerings-, skatte-, tekniksäkerhets-, psykisk hälso-, anställnings-, immigrations-, utbildnings- eller annan professionell rådgivning. Rådgör med en kvalificerad yrkesperson och verifiera resultatet oberoende i högrisksituationer eller professionella sammanhang.

Modeller kan generera felaktiga fakta, bristfällig kod, felaktiga källhänvisningar, vilseledande säkerhetsråd, planer som inte går att genomföra, inaktuella policyer, falska länkar eller olämpligt innehåll. Du bör noga avgöra om du ska använda, sprida, köra, lämna in eller förlita dig på modellutdata.

Palmi är ett gränssnitt för verktyg och arbetsflöden. Det garanterar inte att någon tredjepartsmodell, ändpunkt, något verktyg, någon sökkälla, systemtjänst eller användarkonfiguration alltid är tillgänglig, korrekt, säker, regelriktig eller lämplig för ett visst ändamål.

## 9. Vanliga policyingångar för modelltjänster

Översikten nedan listar policyingångar som kan vara relevanta för Palmis nuvarande snabbval, behållna eller vanliga OpenAI-kompatibla leverantörer, aggregatorer och anpassade modelltjänster. Länkarna är offentliga ingångar eller officiella konsolingångar som samlats in för denna dokumentversion. Leverantörer kan visa olika villkor beroende på land eller region, kontotyp, företagsavtal, API-produkt, modell, driftväg och uppströmsleverantör. Utgå från leverantörens aktuella sida före användning.

### Zhipu AI / GLM / Z.ai / BigModel

Ett av Palmis för närvarande valbara snabbleverantörsalternativ; kan också förekomma via en anpassad OpenAI-kompatibel ändpunkt.

- [BigModel / Zhipu Open Platform](https://open.bigmodel.cn/)
- [Officiell Z.ai-ingång](https://z.ai/)

Granska före användning de senaste användarvillkoren, integritetspolicyn, utvecklarvillkoren och databehandlingsvillkoren som visas i konsolen eller inloggningsflödet.

### DeepSeek

Ett av Palmis för närvarande valbara snabbleverantörsalternativ; kan också nås via det officiella API:et, en aggregator eller en anpassad ändpunkt.

- [DeepSeeks integritetspolicy](https://cdn.deepseek.com/policies/en-US/deepseek-privacy-policy.html)
- [DeepSeeks användarvillkor](https://cdn.deepseek.com/policies/en-US/deepseek-terms-of-use.html)

### Anpassad OpenAI-kompatibel ändpunkt

En bas-URL, API-nyckel och ett modellnamn som användaren anger. Den faktiska tjänsten kan vara en officiell leverantör, aggregator, molnvärd, företagsgateway, lokal server eller tjänst med egen drift.

OpenAI-kompatibel beskriver endast ett API:s form; det betyder inte att OpenAI driver ändpunkten eller att reglerna för integritet, lagring, träning, radering eller överföring är desamma.

Granska den aktuella policyn för ändpunktens ägare, organisationens gateway eller systemet med egen drift innan du skickar data.

### OpenAI / ChatGPT

Kan förekomma via en anpassad ändpunkt, OpenRouter, Azure OpenAI eller en annan driftväg.

- [OpenAI:s integritetspolicy](https://openai.com/policies/privacy-policy/)
- [OpenAI:s användarvillkor](https://openai.com/policies/terms-of-use/)

### Microsoft Azure OpenAI / Azure AI Foundry

Kan användas via en Azure-resurs, ett företagskonto eller en anpassad ändpunkt.

- [Microsofts sekretesspolicy](https://www.microsoft.com/en-us/privacy/privacystatement)
- [Data, integritet och säkerhet för Azure OpenAI](https://learn.microsoft.com/en-us/azure/foundry/responsible-ai/openai/data-privacy)

### Alibaba Cloud Model Studio / DashScope / Qwen

Kan förekomma via OpenAI-kompatibla ändpunkter från Alibaba Cloud Model Studio eller DashScope, anpassade ändpunkter eller aggregatorer.

- [Alibaba Clouds integritetsingång](https://www.aliyun.com/legal/privacy)
- [Ingång till DashScope-dokumentation](https://help.aliyun.com/zh/dashscope/)

För företagskonton bör du också granska Alibaba Clouds användarvillkor, personuppgiftsbiträdesavtal och regionsspecifika regler.

### Moonshot AI / Kimi

Kan förekomma via det officiella Kimi-/Moonshot-API:et, en anpassad ändpunkt eller en aggregator.

- [Moonshot AI Open Platform](https://platform.moonshot.cn/)
- [Officiell Kimi-ingång](https://kimi.moonshot.cn/)

Använd den senaste integritetspolicyn, tjänsteavtalet och API-villkoren som visas på den öppna plattformen eller inloggningssidan.

### MiniMax / Hailuo / Talkie

Kan förekomma via MiniMax officiella API, en anpassad ändpunkt eller en aggregator.

- [MiniMax officiella webbplats](https://www.minimax.io/)
- [MiniMax öppna plattform](https://platform.minimaxi.com/)

Använd integritetspolicyn, tjänsteavtalet och API-villkoren som visas på plattformen och i kontokonsolen.

### Volcengine Ark / Doubao

Kan förekomma via Volcengine Arks OpenAI-kompatibla ändpunkter, en anpassad ändpunkt eller en aggregator.

- [Volcengines integritetsingång](https://www.volcengine.com/docs/6256/64902)
- [Ingång till Volcengine Ark-dokumentation](https://www.volcengine.com/docs/82379)

### Tencent Hunyuan

Kan förekomma via Tencent Cloud Hunyuans API:er, en anpassad ändpunkt eller en aggregator.

- [Tencent Clouds integritetspolicy](https://cloud.tencent.com/document/product/301/11470)
- [Ingång till Tencent Clouds tjänsteavtal](https://cloud.tencent.com/document/product/301/1967)

### Baidu Qianfan / ERNIE

Kan förekomma via Baidu AI Cloud Qianfan-ändpunkter, en anpassad ändpunkt eller en aggregator.

- [Baidus integritetscenter](https://privacy.baidu.com/policy)
- [Ingång till Baidu AI Cloud Qianfan-dokumentation](https://cloud.baidu.com/doc/WENXINWORKSHOP/)

### StepFun

Kan förekomma via StepFuns officiella API, en anpassad ändpunkt eller en aggregator.

- [StepFuns öppna plattform](https://platform.stepfun.com/)

Använd tjänsteavtalet, integritetspolicyn och utvecklarvillkoren som visas i StepFun-konsolen.

### ModelScope

Kan förekomma som ett alternativ för modellhosting eller inferenstjänster.

- [Officiell ModelScope-ingång](https://modelscope.cn/)

Granska ModelScopes användarvillkor, integritetspolicy och det relevanta modellkortet/licensen.

### SiliconFlow

Kan förekomma som en plattform för modellaggregering och inferens.

- [Officiell SiliconFlow-ingång](https://siliconflow.cn/)

Granska dess integritetspolicy, användarvillkor, modelltjänstvillkor och regler för uppströmsmodellleverantörer.

### OpenRouter

Kan förekomma som en global modellaggregator; den valda uppströmsmodellleverantören kan också behandla in- och utdata.

- [OpenRouters integritetspolicy](https://openrouter.ai/privacy)
- [OpenRouters användarvillkor](https://openrouter.ai/terms)

Granska också sidorna om leverantörer/data och policyn för den valda uppströmsmodellleverantören.

### Ollama

Används vanligtvis för lokala modelltjänster eller modelltjänster i lokala nätverk. Om du ansluter officiella molntjänster eller fjärrbaserade tjänster bör du granska deras policyer separat.

- [Ollamas integritetspolicy](https://ollama.com/privacy)
- [Ollamas villkor](https://ollama.com/terms)

### LM Studio

Används vanligtvis för lokala skrivbordsmodelltjänster eller modelltjänster i lokala nätverk. Granska dess policyer om fjärrnedladdningar, konton, synkronisering eller värdbaserade tjänster aktiveras.

- [LM Studios integritetspolicy](https://lmstudio.ai/privacy)
- [LM Studios villkor](https://lmstudio.ai/terms)

### Anthropic / Claude

Palmi förkonfigurerar för närvarande inte Anthropics inbyggda protokoll direkt, men Claude kan förekomma via OpenRouter, en företagsgateway eller ett anpassat kompatibilitetslager.

- [Anthropics integritetspolicy](https://www.anthropic.com/legal/privacy)
- [Anthropics villkor och policyer](https://www.anthropic.com/legal)

### Google Gemini / Google AI Studio / Vertex AI

Kan förekomma via Google-API:er, Vertex AI, en aggregator eller en företagsgateway.

- [Googles integritetspolicy](https://policies.google.com/privacy)
- [Google Clouds integritetsinformation](https://cloud.google.com/terms/cloud-privacy-notice)
- [Ytterligare villkor för Google AI / Gemini API](https://ai.google.dev/terms)

### Mistral AI

Kan förekomma via Mistrals officiella API, en aggregator eller en företagsgateway.

- [Mistral AI:s juridiska center](https://legal.mistral.ai/terms)
- [Mistral AI:s integritetspolicy](https://legal.mistral.ai/terms/privacy-policy)

### Meta / Llama

Förekommer vanligtvis via tredjepartsdrift, en molnleverantör, aggregator, lokal driftsättning eller företagsgateway. En offentlig modelllicens är inte en driftstjänsts integritetspolicy.

- [Metas integritetspolicy](https://www.facebook.com/privacy/policy/)
- [Llamas officiella webbplats](https://www.llama.com/)

Granska också policyn för den faktiska värden, molnleverantören eller lokala driftansvariga.

### xAI / Grok

Kan förekomma via det officiella API:et, en aggregator eller en företagsgateway.

- [xAI:s integritetspolicy](https://x.ai/legal/privacy-policy)
- [xAI:s användarvillkor](https://x.ai/legal/terms-of-service)

### Cohere

Kan förekomma via Coheres officiella API, en aggregator eller en företagsgateway.

- [Coheres integritetspolicy](https://cohere.com/privacy)
- [Coheres användarvillkor](https://cohere.com/terms-of-use)

### Hugging Face / Inference Providers

Kan förekomma för modellnedladdningar, värdbaserad inferens, Spaces eller tredjepartsleverantörer av inferens.

- [Hugging Faces integritetspolicy](https://huggingface.co/privacy)
- [Hugging Faces användarvillkor](https://huggingface.co/terms-of-service)

Granska också den faktiska inferensleverantören och den relevanta modelllicensen.

### Together AI / Fireworks AI / Groq / Replicate / Perplexity / AI21 Labs

Dessa tjänster kan förekomma via anpassade ändpunkter, aggregatorer, SDK:er, företagsgateways eller uppströmsdriftvägar.

- [Together AI:s integritetspolicy](https://www.together.ai/privacy)
- [Fireworks AI:s integritetspolicy](https://fireworks.ai/privacy)
- [Groqs integritetspolicy](https://groq.com/privacy-policy/)
- [Replicates integritetspolicy](https://replicate.com/privacy)
- [Perplexitys integritetspolicy](https://www.perplexity.ai/hub/legal/privacy-policy)
- [AI21 Labs integritetspolicy](https://www.ai21.com/privacy-policy)

### iFlytek Spark / Huawei Cloud Pangu / SenseTime / Baichuan / 01.AI / Xiaomi / Meituan och andra leverantörer

Kan förekomma via en anpassad ändpunkt, molnmarknadsplats, företagsgateway, lokal driftsättning eller aggregator. Tillämpliga regler varierar med konto, region, tjänsteform och värd.

- [Integritetsingång för iFlyteks öppna plattform](https://www.xfyun.cn/doc/policy/privacy.html)
- [Huawei Clouds integritetsingång](https://www.huaweicloud.com/declaration/sa_prp.html)
- [Ingång till Xiaomis integritetspolicy](https://privacy.mi.com/all/zh_CN/)

För Meituan LongCat, Baichuan, 01.AI, SenseTime och liknande tjänster ska du använda den senaste policyn som visas på leverantörens officiella webbplats, öppna plattform eller modelltjänstkonsol.

Om en tjänst inte finns med ovan gäller samma regel: bekräfta ändpunktens ägare, tjänstens juridiska aktör, uppströmsleverantör, tillämplig region, policy för loggning och träning, metoder för radering och export, kostnader och gränser för regelefterlevnad.

## 10. Användarbekräftelse

1. Jag förstår att Palmi är en agentapp som i första hand arbetar lokalt och ett gränssnitt för modellanslutning, och att den nuvarande utformningen inte använder en centraliserad serverdatabas som Palmi driver för chattinnehåll, arbetsytefiler, bilagor eller API-nycklar.
2. Jag förstår att när jag konfigurerar eller använder en tredjepartsmodell, aggregator, sökkälla, systemtjänst, företagsgateway, lokal eller fjärrbaserad ändpunkt med egen drift eller något annat verktyg kan innehållet jag väljer att skicka och nödvändiga metadata behandlas av den tjänsten.
3. Jag förstår att tredje partens datalagring, användning för träning, uppströmsdirigering, gränsöverskridande överföring, begäranden om radering, kontosäkerhet, kostnader och tvisthantering styrs av den tredje partens aktuella policyer och mitt avtal med den.
4. Jag kommer endast att skicka personuppgifter, företagsmaterial, kunddata, filer, bilder, kod eller annat innehåll när jag har tillräckliga rättigheter, behörighet och grund för regelefterlevnad, och jag kommer att använda mänsklig granskning i högrisksituationer.
5. Om jag inte godkänner denna information eller inte har bekräftat policyn för leverantören jag valt kan jag avbryta modellkonfigurationen eller gå tillbaka och ändra mitt val.

Dokumentet är avsett som användarinformation i produkten och som bekräftelse för användningen. Det är inte individuell juridisk rådgivning för någon användare, organisation, bransch eller jurisdiktion. Före officiell publicering, inlämning till appbutik, kommersiell lansering eller användning i reglerade branscher rekommenderas granskning av kvalificerade yrkespersoner i relevanta jurisdiktioner.
