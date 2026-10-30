# Palmi-Hinweis zu Datenschutz und KI-Diensten Dritter

Dokument zum Lesen und Bestätigen vor der erstmaligen Modellkonfiguration

Version: v26.7  
Versionsdatum: 2026.07.01  
Zielgruppe: Nutzer der mobilen App Palmi / PalmiAgent

**Wichtig:** Lies dieses Dokument, bevor du ein Modell konfigurierst. Die Auswahl „Ich habe gelesen und stimme zu“ bedeutet, dass du die hier beschriebenen Datenflüsse, Grenzen von Drittanbieterdiensten, Vorsichtsmaßnahmen bei sensiblen Informationen und Verantwortlichkeiten bei Nutzerentscheidungen verstehst und bestätigst. Dies bedeutet nicht, dass du Drittanbieterbedingungen akzeptiert hast, die dir nicht angezeigt wurden. Maßgeblich sind die aktuellen offiziellen Bedingungen auf den von diesen Diensten veröffentlichten Seiten.

## 1. Zweck und Geltungsbereich

Dieses Dokument ist der Palmi-Nutzerhinweis (PalmiAgent), der vor der erstmaligen Modellkonfiguration angezeigt wird. Er erläutert mögliche Datenflüsse zwischen der lokalen App, vom Nutzer ausgewählten Modelldiensten, Systemberechtigungen und Drittanbieterwerkzeugen und fordert vor dem Fortfahren eine ausdrückliche Bestätigung des Nutzers.

Dieses Dokument ist nicht die Datenschutzrichtlinie eines Modellanbieters. Es ersetzt weder die Nutzungsbedingungen, Datenschutzrichtlinie, Entwicklervereinbarung, Auftragsverarbeitungsvereinbarung, Richtlinie zur akzeptablen Nutzung, Modelllizenz noch die Sicherheitsregeln eines Drittanbieter-Modellanbieters, Cloudanbieters, Modellaggregators, Unternehmensgateways, Systemdiensts oder einer lokalen Bereitstellung.

Palmi ist eine Agenten-App mit vorrangig lokaler Verarbeitung und eine Schnittstelle zur Modellanbindung. Das gewählte Modell, die eingegebene Basis-URL, der verwendete API-Schlüssel, die gesendeten Inhalte sowie die aktivierten Systemberechtigungen oder Werkzeuge bestimmen, ob Daten dein Gerät verlassen und wer sie verarbeitet.

## 2. Lokale Datenverarbeitung im aktuellen Produktdesign

Im aktuellen Produktdesign betreibt Palmi keine eigene zentrale serverseitige Datenbank für deine Chatinhalte, Arbeitsbereichsdateien, Anhänge oder API-Schlüssel. Projekte, Unterhaltungen, Arbeitsbereichsdateien, Anhänge, Ausführungsaufzeichnungen, Caches und Einstellungen werden hauptsächlich im App-Container auf deinem Gerät gespeichert. Modellzugangsdaten sollten im Systemschlüsselbund oder einem gleichwertigen sicheren Zugangsdaten-Speicher abgelegt werden.

Lokale OCR, Dateivorschau, Lesen und Schreiben im Arbeitsbereich, eingebettetes Python, lokale Caches, Gesprächsverwaltung und Datenbereinigung laufen üblicherweise auf dem Gerät. Sofern du kein entferntes Modell, keine entfernte Suche, keinen entfernten Dateidienst, keine Cloudsynchronisierung, Freigabe bzw. Exportfunktion oder andere Drittanbieterfunktion konfigurierst, werden diese Materialien normalerweise nicht von Palmi selbst an einen von Palmi betriebenen entfernten Server gesendet.

Systeme auf Geräteebene, iCloud oder Systemsicherungen, Absturzdiagnosen, der App Store, unternehmensseitige Mobilgeräteverwaltung, Netzwerkproxies, VPNs, Sicherheitswerkzeuge und vom Nutzer veranlasste Exporte können Daten gemäß den Regeln von Apple, eines Organisationsadministrators, eines Netzwerkdienstes oder eines von dir ausgewählten Drittanbieters verarbeiten. Palmi kontrolliert diese systemweiten oder vom Nutzer ausgewählten Prozesse nicht.

## 3. Wann Daten das Gerät verlassen können

Wenn du einen entfernten Modelldienst, Modellaggregator, cloudgehosteten Endpunkt, ein Unternehmensgateway oder einen benutzerdefinierten OpenAI-kompatiblen Endpunkt konfigurierst und verwendest, können Prompts, Kontext, Dateizusammenfassungen, Bilder, Werkzeugergebnisse, Modellrollenkonfigurationen, Teile von Systemanweisungen, Gesprächsverläufe, Fehlerinformationen und erforderliche Anfragemetadaten an diesen Dienst gesendet werden.

Wenn du Websuche, Lesen von Webseiten, Karten, E-Mail, Nachrichten, Telefon, Kalender, Erinnerungen, Kontakte, Standort, Kamera, Fotos, Spracherkennung, Mitteilungen, Spotlight, Systemweiterleitung oder andere Werkzeugfunktionen aktivierst, können zugehörige Daten vom jeweiligen Systemdienst, Suchanbieter, der Website, dem Kontodienst, der Unternehmensumgebung oder dem Netzwerkdienst verarbeitet werden.

Wenn du eine Datei importierst, öffnest, kopierst, teilst, exportierst, sendest oder hochlädst oder einen Agenten anweist, eine externe Aktion mit einer Datei durchzuführen, können die Datei oder ihre Inhalte an einen von dir gewählten Ort geschrieben, an eine von dir gewählte App, einen Anbieter oder Kontakt gesendet oder in Caches und Protokolle des betreffenden Systems aufgenommen werden.

Netzwerkübertragung erfordert normalerweise eine Verbindung. Netzbetreiber, DNS-Anbieter, Proxies, VPNs, Gateways, Firewalls, Unternehmenssicherheitsprodukte oder Drittanbieterdienste können Netzwerkmetadaten nach ihren eigenen Regeln verarbeiten.

## 4. Modelldienste, OpenAI-kompatible Endpunkte und Verantwortungsgrenzen

OpenAI-kompatibel beschreibt lediglich Ähnlichkeiten bei Endpunktgestaltung, Authentifizierung, Anfrageformat, Nachrichtenstruktur, Streaming oder Werkzeugaufrufformat. Es bedeutet nicht, dass OpenAI den Dienst betreibt oder dass der Dienst dieselben Regeln zu Sicherheit, Aufbewahrung, Training, Löschung, grenzüberschreitender Übermittlung, Streitigkeiten oder rechtlichen Fragen wie OpenAI hat.

Drittanbieter-Modelldienste, Cloudanbieter, Modellaggregatoren, Unternehmensgateways und selbst gehostete Dienste können als eigenständige Verantwortliche, Auftragsverarbeiter, gemeinsam Verantwortliche, Infrastrukturanbieter oder Modellhosts handeln. Ihre aktuellen Richtlinien und Kontovereinbarungen regeln, wie sie protokollieren, Eingaben und Ausgaben aufbewahren, Sicherheitsprüfungen durchführen, Daten zum Modelltraining verwenden, Daten an vorgelagerte Modelle weiterleiten, Löschanträge bearbeiten oder auf behördliche und regulatorische Anfragen reagieren.

Palmi kann für dich nicht die Eigentümerschaft eines eingegebenen Endpunkts, die Herkunft eines API-Schlüssels, Kontoberechtigungen, Dienstregion, Abrechnungsverantwortung, Aufbewahrungsdauer, Trainingseinstellungen, eine Konfiguration ohne Datenaufbewahrung, unternehmensbezogene Datenschutzbedingungen oder den tatsächlichen vorgelagerten Modellverarbeiter überprüfen. Du solltest diese Punkte vor der Nutzung bestätigen.

## 5. Sensible Inhalte, Unternehmensmaterialien und Daten anderer Personen

Du solltest keine Passwörter, API-Schlüssel, privaten Schlüssel, Identitätsnummern, Bankkartendaten, Gesundheitsinformationen, Informationen über Minderjährige, genauen Standorte, Kontakte, Chatverläufe, Kundendaten, Geheimnisse im Quellcode, Geschäftsgeheimnisse, unveröffentlichte Forschungsergebnisse, durch Geheimhaltungsvereinbarungen geschützten Inhalte, regulierten Daten oder Materialien übermitteln, die Rechte anderer Personen beeinträchtigen könnten, sofern du nicht über ausreichende Befugnisse, eine Rechtsgrundlage und eine Sicherheitsprüfung verfügst.

Wenn du Palmi im Namen eines Unternehmens, einer Schule, eines Labors, Projektteams, Kunden, Familienmitglieds oder eines anderen Dritten verwendest, solltest du bestätigen, dass du befugt bist, Modelldienste zu konfigurieren, die betreffenden Inhalte zu senden, Systemberechtigungen zu erteilen, Werkzeuge aufzurufen und Dateien hochzuladen oder zu exportieren. Außerdem solltest du die Anforderungen dieser Organisation an Datenklassifizierung, Vertraulichkeit, Compliance, Beschaffung und Sicherheitsfreigaben erfüllen.

Wenn du nicht sicher bist, ob eine Informationskategorie an ein Modell oder einen Drittanbieterdienst gesendet werden darf, sende sie standardmäßig nicht. Erwäge Schwärzung, Zusammenfassung, Anonymisierung, lokale Verarbeitung, interne Genehmigung oder einen Unternehmensdienst, der die geltenden Compliance-Anforderungen erfüllt.

## 6. Werkzeugaufrufe, Systemberechtigungen und externe Aktionen

Die Agentenfunktionen von Palmi können das Lesen oder Erzeugen von Dateien, Änderungen am Arbeitsbereich, Websuchen, den Zugriff auf Kalender, Erinnerungen, Kontakte, Standort, Fotos, Kamera, Sprache, Systemapps und Nachrichtenentwürfe oder andere Systemaktionen vorschlagen oder auslösen. Verschiedene Werkzeuge können iOS-Berechtigungen, Nutzerbestätigungen, Drittanbieter-Kontoautorisierungen oder Freigaben gemäß Organisationsrichtlinien erfordern.

Jede Aktion, die ein externes System, eine andere Person, Kontovermögen, Zeitpläne, Dateizustände, Nachrichtenversand, Käufe, Zahlungen, Bereitstellungen, Löschungen oder öffentliche Offenlegung beeinflussen kann, sollte vor der Ausführung von einem Menschen geprüft werden. Modellausgaben können unvollständig, ungenau, veraltet, erfunden, verzerrt oder mit deiner Absicht unvereinbar sein.

Das Risiko steigt erheblich, wenn du automatische Genehmigungen, Stapelausführung, Skriptausführung, Webautomatisierung, Systemweiterleitung oder Unternehmenswerkzeugintegrationen aktivierst. Verwende diese Funktionen nur für vertrauenswürdige Aufgaben und in Umgebungen, in denen Änderungen rückgängig gemacht werden können.

## 7. Lokale Datenverwaltung, Widerruf und Löschung

Du kannst lokale Daten und Drittanbieter-Kontodaten über die Datenverwaltung in der App, Systemeinstellungen, iOS-Berechtigungseinstellungen, das Zurücksetzen von Schlüsselbund oder Zugangsdaten, Anbieterkonsolen, Drittanbieter-Kontoportale, Organisationsadministratoren, Supportanfragen an Cloudanbieter oder die Deinstallation der App verwalten.

Das Leeren des lokalen Palmi-Arbeitsbereichs, von Caches, Einstellungen oder Modellzugangsdaten betrifft nur Daten auf dem Gerät oder von Palmi aufbewahrte Kopien. Es löscht nicht automatisch Daten, die bereits an Drittanbieter-Modelldienste, Suchanbieter, Websites, Cloudanbieter, Aggregatoren, Unternehmensgateways, Systemdienste oder andere Apps gesendet wurden. Zugriff, Berichtigung, Export, Löschung, Ausschluss vom Training, Erinnerungssteuerungen oder Einstellungen zur Protokollaufbewahrung auf Drittanbieterseite müssen gemäß den Richtlinien und Kontowerkzeugen dieses Anbieters behandelt werden.

Das Löschen oder Deinstallieren der App kann weiterhin von Systemsicherungen, Unternehmensgeräteverwaltung, Protokollen, exportierten Dateien, freigegebenen Kopien, Aufbewahrungsfristen Dritter und gesetzlichen Aufbewahrungspflichten beeinflusst werden.

## 8. Hinweis zu KI-Ausgaben und beruflichen Risiken

Modellausgaben sind keine rechtliche, medizinische, finanzielle, Anlage-, Steuer-, Ingenieursicherheits-, psychologische, Beschäftigungs-, Einwanderungs-, Bildungs- oder sonstige Fachberatung. Wende dich in risikoreichen oder fachlichen Situationen an qualifizierte Fachleute und überprüfe das Ergebnis unabhängig.

Modelle können falsche Fakten, fehlerhaften Code, falsche Quellenangaben, irreführende Sicherheitshinweise, nicht ausführbare Pläne, veraltete Richtlinien, falsche Links oder unangemessene Inhalte erzeugen. Du solltest sorgfältig entscheiden, ob du Modellausgaben verwendest, weitergibst, ausführst, einreichst oder dich darauf verlässt.

Palmi ist eine Werkzeug- und Arbeitsablaufschnittstelle. Es garantiert nicht, dass Drittanbietermodelle, Endpunkte, Werkzeuge, Suchquellen, Systemdienste oder Nutzerkonfigurationen immer verfügbar, korrekt, sicher, regelkonform oder für einen bestimmten Zweck geeignet sind.

## 9. Häufige Richtlinienzugänge für Modelldienste

Die folgende Übersicht enthält Richtlinienzugänge, die für die aktuellen Schnellauswahlen von Palmi, beibehaltene oder verbreitete OpenAI-kompatible Anbieter, Aggregatoren und benutzerdefinierte Modelldienste relevant sein können. Links sind öffentliche Zugänge oder offizielle Konsolenzugänge, die für diese Dokumentversion gesammelt wurden. Anbieter können je nach Land oder Region, Kontotyp, Unternehmensvereinbarung, API-Produkt, Modell, Hostingweg und vorgelagertem Anbieter unterschiedliche Bedingungen anzeigen. Verlasse dich vor der Nutzung auf die aktuelle Seite des Anbieters.

### Zhipu AI / GLM / Z.ai / BigModel

Einer der derzeit auswählbaren Anbieter-Schnelleinträge von Palmi; kann auch über einen benutzerdefinierten OpenAI-kompatiblen Endpunkt erscheinen.

- [BigModel / Zhipu Open Platform](https://open.bigmodel.cn/)
- [Offizieller Z.ai-Zugang](https://z.ai/)

Prüfe vor der Nutzung die neuesten Nutzungsbedingungen, Datenschutzrichtlinien, Entwicklerbedingungen und Datenverarbeitungsbedingungen, die in der Konsole oder im Anmeldeablauf angezeigt werden.

### DeepSeek

Einer der derzeit auswählbaren Anbieter-Schnelleinträge von Palmi; auch über die offizielle API, einen Aggregator oder einen benutzerdefinierten Endpunkt erreichbar.

- [DeepSeek-Datenschutzrichtlinie](https://cdn.deepseek.com/policies/en-US/deepseek-privacy-policy.html)
- [DeepSeek-Nutzungsbedingungen](https://cdn.deepseek.com/policies/en-US/deepseek-terms-of-use.html)

### Benutzerdefinierter OpenAI-kompatibler Endpunkt

Eine vom Nutzer bereitgestellte Basis-URL, ein API-Schlüssel und ein Modellname. Der tatsächliche Dienst kann ein offizieller Anbieter, Aggregator, Cloudhost, Unternehmensgateway, lokaler Server oder selbst gehosteter Dienst sein.

OpenAI-kompatibel beschreibt nur die Form einer API; es bedeutet nicht, dass OpenAI den Endpunkt betreibt oder dass die Regeln für Datenschutz, Aufbewahrung, Training, Löschung oder Übermittlung gleich sind.

Prüfe die aktuelle Richtlinie des Endpunkteigentümers, Organisationsgateways oder selbst gehosteten Systems, bevor du Daten sendest.

### OpenAI / ChatGPT

Kann über einen benutzerdefinierten Endpunkt, OpenRouter, Azure OpenAI oder einen anderen Hostingweg erscheinen.

- [OpenAI-Datenschutzrichtlinie](https://openai.com/policies/privacy-policy/)
- [OpenAI-Nutzungsbedingungen](https://openai.com/policies/terms-of-use/)

### Microsoft Azure OpenAI / Azure AI Foundry

Kann über eine Azure-Ressource, ein Unternehmenskonto oder einen benutzerdefinierten Endpunkt verwendet werden.

- [Microsoft-Datenschutzerklärung](https://www.microsoft.com/en-us/privacy/privacystatement)
- [Daten, Datenschutz und Sicherheit bei Azure OpenAI](https://learn.microsoft.com/en-us/azure/foundry/responsible-ai/openai/data-privacy)

### Alibaba Cloud Model Studio / DashScope / Qwen

Kann über OpenAI-kompatible Endpunkte von Alibaba Cloud Model Studio oder DashScope, benutzerdefinierte Endpunkte oder Aggregatoren erscheinen.

- [Alibaba Cloud-Datenschutzzugang](https://www.aliyun.com/legal/privacy)
- [DashScope-Dokumentationszugang](https://help.aliyun.com/zh/dashscope/)

Prüfe bei Unternehmenskonten auch die Alibaba Cloud-Nutzungsbedingungen, Datenverarbeitungsvereinbarungen und regionsspezifischen Regeln.

### Moonshot AI / Kimi

Kann über die offizielle Kimi-/Moonshot-API, einen benutzerdefinierten Endpunkt oder einen Aggregator erscheinen.

- [Moonshot AI Open Platform](https://platform.moonshot.cn/)
- [Offizieller Kimi-Zugang](https://kimi.moonshot.cn/)

Verwende die neueste Datenschutzrichtlinie, Dienstvereinbarung und API-Bedingungen, die auf der offenen Plattform oder Anmeldeseite angezeigt werden.

### MiniMax / Hailuo / Talkie

Kann über die offizielle MiniMax-API, einen benutzerdefinierten Endpunkt oder einen Aggregator erscheinen.

- [Offizielle MiniMax-Website](https://www.minimax.io/)
- [MiniMax Open Platform](https://platform.minimaxi.com/)

Verwende die Datenschutzrichtlinie, Dienstvereinbarung und API-Bedingungen, die auf der Plattform und in der Kontokonsole angezeigt werden.

### Volcengine Ark / Doubao

Kann über OpenAI-kompatible Endpunkte von Volcengine Ark, einen benutzerdefinierten Endpunkt oder einen Aggregator erscheinen.

- [Volcengine-Datenschutzzugang](https://www.volcengine.com/docs/6256/64902)
- [Volcengine Ark-Dokumentationszugang](https://www.volcengine.com/docs/82379)

### Tencent Hunyuan

Kann über Tencent Cloud Hunyuan-APIs, einen benutzerdefinierten Endpunkt oder einen Aggregator erscheinen.

- [Tencent Cloud-Datenschutzerklärung](https://cloud.tencent.com/document/product/301/11470)
- [Zugang zur Tencent Cloud-Dienstvereinbarung](https://cloud.tencent.com/document/product/301/1967)

### Baidu Qianfan / ERNIE

Kann über Baidu AI Cloud Qianfan-Endpunkte, einen benutzerdefinierten Endpunkt oder einen Aggregator erscheinen.

- [Baidu-Datenschutzzentrum](https://privacy.baidu.com/policy)
- [Baidu AI Cloud Qianfan-Dokumentationszugang](https://cloud.baidu.com/doc/WENXINWORKSHOP/)

### StepFun

Kann über die offizielle StepFun-API, einen benutzerdefinierten Endpunkt oder einen Aggregator erscheinen.

- [StepFun Open Platform](https://platform.stepfun.com/)

Verwende die Dienstvereinbarung, Datenschutzrichtlinie und Entwicklerbedingungen, die in der StepFun-Konsole angezeigt werden.

### ModelScope

Kann als Eintrag für Modellhosting oder Inferenzdienste erscheinen.

- [Offizieller ModelScope-Zugang](https://modelscope.cn/)

Prüfe die ModelScope-Nutzungsbedingungen, Datenschutzrichtlinie und die jeweilige Modellkarte/Lizenz.

### SiliconFlow

Kann als Plattform für Modellaggregation und Inferenz erscheinen.

- [Offizieller SiliconFlow-Zugang](https://siliconflow.cn/)

Prüfe die Datenschutzrichtlinie, Nutzungsbedingungen, Modelldienstbedingungen und Regeln der vorgelagerten Modellanbieter.

### OpenRouter

Kann als globaler Modellaggregator erscheinen; der gewählte vorgelagerte Modellanbieter kann ebenfalls Eingaben und Ausgaben verarbeiten.

- [OpenRouter-Datenschutzrichtlinie](https://openrouter.ai/privacy)
- [OpenRouter-Nutzungsbedingungen](https://openrouter.ai/terms)

Prüfe außerdem die Anbieter-/Datenseiten sowie die Richtlinie des gewählten vorgelagerten Modellanbieters.

### Ollama

Üblicherweise für lokale oder LAN-Modelldienste verwendet. Wenn du offizielle Cloud- oder entfernt gehostete Dienste verbindest, prüfe deren Richtlinien separat.

- [Ollama-Datenschutzrichtlinie](https://ollama.com/privacy)
- [Ollama-Bedingungen](https://ollama.com/terms)

### LM Studio

Üblicherweise für lokale Desktop- oder LAN-Modelldienste verwendet. Prüfe die Richtlinien, wenn entfernte Downloads, Konten, Synchronisierung oder gehostete Dienste aktiviert sind.

- [LM Studio-Datenschutz](https://lmstudio.ai/privacy)
- [LM Studio-Bedingungen](https://lmstudio.ai/terms)

### Anthropic / Claude

Palmi konfiguriert Anthropics natives Protokoll derzeit nicht direkt vor; Claude kann jedoch über OpenRouter, ein Unternehmensgateway oder eine benutzerdefinierte Kompatibilitätsschicht erscheinen.

- [Anthropic-Datenschutzrichtlinie](https://www.anthropic.com/legal/privacy)
- [Anthropic-Bedingungen und -Richtlinien](https://www.anthropic.com/legal)

### Google Gemini / Google AI Studio / Vertex AI

Kann über Google-APIs, Vertex AI, einen Aggregator oder ein Unternehmensgateway erscheinen.

- [Google-Datenschutzrichtlinie](https://policies.google.com/privacy)
- [Google Cloud-Datenschutzhinweis](https://cloud.google.com/terms/cloud-privacy-notice)
- [Zusätzliche Bedingungen für Google AI / Gemini API](https://ai.google.dev/terms)

### Mistral AI

Kann über die offizielle Mistral-API, einen Aggregator oder ein Unternehmensgateway erscheinen.

- [Mistral AI-Rechtszentrum](https://legal.mistral.ai/terms)
- [Mistral AI-Datenschutzrichtlinie](https://legal.mistral.ai/terms/privacy-policy)

### Meta / Llama

Erscheint üblicherweise über Drittanbieterhosting, Cloudanbieter, Aggregatoren, lokale Bereitstellungen oder Unternehmensgateways. Eine öffentliche Modelllizenz ist keine Datenschutzrichtlinie eines Hostingdiensts.

- [Meta-Datenschutzrichtlinie](https://www.facebook.com/privacy/policy/)
- [Offizielle Llama-Website](https://www.llama.com/)

Prüfe auch die Richtlinie des tatsächlichen Hosts, Cloudanbieters oder lokalen Bereitstellers.

### xAI / Grok

Kann über die offizielle API, einen Aggregator oder ein Unternehmensgateway erscheinen.

- [xAI-Datenschutzrichtlinie](https://x.ai/legal/privacy-policy)
- [xAI-Nutzungsbedingungen](https://x.ai/legal/terms-of-service)

### Cohere

Kann über die offizielle Cohere-API, einen Aggregator oder ein Unternehmensgateway erscheinen.

- [Cohere-Datenschutzrichtlinie](https://cohere.com/privacy)
- [Cohere-Nutzungsbedingungen](https://cohere.com/terms-of-use)

### Hugging Face / Inference Providers

Kann für Modelldownloads, gehostete Inferenz, Spaces oder Inferenzanbieter Dritter erscheinen.

- [Hugging Face-Datenschutzrichtlinie](https://huggingface.co/privacy)
- [Hugging Face-Nutzungsbedingungen](https://huggingface.co/terms-of-service)

Prüfe auch den tatsächlichen Inferenzanbieter und die jeweilige Modelllizenz.

### Together AI / Fireworks AI / Groq / Replicate / Perplexity / AI21 Labs

Diese Dienste können über benutzerdefinierte Endpunkte, Aggregatoren, SDKs, Unternehmensgateways oder vorgelagerte Hostingwege erscheinen.

- [Together AI-Datenschutz](https://www.together.ai/privacy)
- [Fireworks AI-Datenschutz](https://fireworks.ai/privacy)
- [Groq-Datenschutzrichtlinie](https://groq.com/privacy-policy/)
- [Replicate-Datenschutz](https://replicate.com/privacy)
- [Perplexity-Datenschutzrichtlinie](https://www.perplexity.ai/hub/legal/privacy-policy)
- [AI21 Labs-Datenschutzrichtlinie](https://www.ai21.com/privacy-policy)

### iFlytek Spark / Huawei Cloud Pangu / SenseTime / Baichuan / 01.AI / Xiaomi / Meituan und andere Anbieter

Können über einen benutzerdefinierten Endpunkt, Cloudmarktplatz, ein Unternehmensgateway, eine lokale Bereitstellung oder einen Aggregator erscheinen. Geltende Regeln unterscheiden sich je nach Konto, Region, Dienstform und Host.

- [iFlytek Open Platform-Datenschutzzugang](https://www.xfyun.cn/doc/policy/privacy.html)
- [Huawei Cloud-Datenschutzzugang](https://www.huaweicloud.com/declaration/sa_prp.html)
- [Xiaomi-Datenschutzrichtlinienzugang](https://privacy.mi.com/all/zh_CN/)

Verwende für Meituan LongCat, Baichuan, 01.AI, SenseTime und ähnliche Dienste die neueste Richtlinie, die auf der offiziellen Website, offenen Plattform oder Modelldienstkonsole des Anbieters angezeigt wird.

Wenn ein Dienst oben nicht aufgeführt ist, gilt dieselbe Regel: Bestätige Endpunkteigentümerschaft, Dienstunternehmen, vorgelagerten Anbieter, geltende Region, Protokollierungs- und Trainingsrichtlinie, Lösch- und Exportmethoden, Kosten und Compliance-Grenzen.

## 10. Nutzerbestätigung

1. Ich verstehe, dass Palmi eine Agenten-App mit vorrangig lokaler Verarbeitung und eine Schnittstelle zur Modellanbindung ist und dass das aktuelle Design keine von Palmi betriebene zentrale serverseitige Datenbank für Chatinhalte, Arbeitsbereichsdateien, Anhänge oder API-Schlüssel verwendet.
2. Ich verstehe, dass bei der Konfiguration oder Nutzung eines Drittanbietermodells, Aggregators, einer Suchquelle, eines Systemdiensts, Unternehmensgateways, lokalen oder entfernten selbst gehosteten Endpunkts oder anderen Werkzeugs die von mir ausgewählten Inhalte und erforderlichen Metadaten von diesem Dienst verarbeitet werden können.
3. Ich verstehe, dass Datenaufbewahrung, Trainingsnutzung, vorgelagerte Weiterleitung, grenzüberschreitende Übermittlung, Löschanträge, Kontosicherheit, Kosten und Streitbeilegung beim Drittanbieter dessen aktuellen Richtlinien und meiner Vereinbarung mit ihm unterliegen.
4. Ich werde personenbezogene Informationen, Unternehmensmaterialien, Kundendaten, Dateien, Bilder, Code oder andere Inhalte nur übermitteln, wenn ich ausreichende Rechte, Befugnisse und Compliance-Grundlagen habe, und in risikoreichen Situationen eine menschliche Prüfung einsetzen.
5. Wenn ich diesem Hinweis nicht zustimme oder die Richtlinie des gewählten Anbieters nicht bestätigt habe, kann ich die Modellkonfiguration beenden oder zurückgehen und meine Auswahl ändern.

Dieses Dokument dient als Nutzerhinweis innerhalb des Produkts und zur betrieblichen Bestätigung. Es ist keine individuelle Rechtsberatung für Nutzer, Organisationen, Branchen oder Rechtsordnungen. Vor offizieller Veröffentlichung, App-Store-Einreichung, kommerziellem Start oder Nutzung in regulierten Branchen wird eine Prüfung durch qualifizierte Fachleute in den jeweiligen Rechtsordnungen empfohlen.
