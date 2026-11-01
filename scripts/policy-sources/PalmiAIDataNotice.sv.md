# Meddelande om dataöverföring till AI-tjänster från tredje part

Version: v26.11  Versionsdatum: 2026.11.01

PalmiAgent är ett AI-verktyg som i första hand arbetar lokalt. Det driver ingen molnserver för modeller som tar emot, lagrar eller analyserar dina chattar, bilagor eller verktygsresultat, och det samlar inte självständigt in och laddar upp denna information för AI-bearbetning om du inte har vidtagit en åtgärd eller gett relevant tillstånd. Först efter att du har konfigurerat en modell i nästa steg, startat en AI-begäran och valt relevant innehåll skickar appen det innehåll som behövs för begäran till den AI-modelltjänst från tredje part som du själv väljer.

## 1. Data som kan skickas

1. Meddelanden, promptar och instruktioner som du aktivt anger, tillsammans med tidigare meddelanden, konversationskontext och uppgiftstillstånd som modellen behöver för att förstå och slutföra den aktuella begäran; att bara öppna appen, stanna på en skärm eller flytta appen till bakgrunden laddar inte i sig upp orelaterade chattar;
2. Bilder, dokument och andra filer som du uttryckligen lägger till i den aktuella uppgiften, inklusive extraherad text, OCR-resultat, filformatsinformation eller nödvändiga sammanfattningar som hjälper modellen att förstå bilagorna; andra lokala filer som du inte lägger till i begäran skickas inte av detta skäl;
3. Resultat från kalender, påminnelser, kontakter, plats, bilder eller andra verktyg som ingår i den aktuella uppgiften efter att du separat har gett relevant iOS-behörighet och uttryckligen anropat verktyget; att ge systembehörighet är inte i sig samtycke till att överföra data, och endast resultat som faktiskt används av den aktuella AI-begäran får skickas;
4. Systeminstruktioner, verktygsdefinitioner och resultat, modellidentifierare, genereringsparametrar och teknisk information som behövs för att organisera, slutföra eller återställa den aktuella begäran; informationen används för att tredjepartsmodellen ska kunna behandla uppgiften du startat korrekt.

## 2. Mottagare

Mottagaren är den AI-modelltjänst och operatör av API-ändpunkten från tredje part som du själv väljer eller anger och bekräftar i nästa steg, inte PalmiAgent. Appen förväljer, rekommenderar eller antyder ingen viss tjänst i detta meddelande och visar ingen konfiguration som du ännu inte har slutfört. Efter konfigurationen skickas innehåll i en AI-begäran som du startar över nätverket till ett gränssnitt som kontrolleras av tjänsteoperatören. Den specifika juridiska operatören, serverregionen och den faktiska personuppgiftsbehandlaren beror på tjänsten och villkoren du till sist väljer. Om du inte kan verifiera eller inte litar på tjänstens identitet, integritetspolicy eller regler för datahantering ska du inte slutföra dess konfiguration eller skicka innehåll till den.

## 3. Syfte

Innehållet skickas bara för att behandla begäranden som du aktivt startar, bland annat för att generera modellsvar, förstå bilder eller filer du väljer, utföra agentuppgifter du begär och upprätthålla den kontext som behövs för begäran. Tredjepartstjänsten kan logga, granska, behålla, skicka vidare till uppströmsbehandlare eller radera data enligt sin egen integritetspolicy, sina villkor och kontoinställningar. PalmiAgent kan inte bestämma denna tredje parts lagringstid, användning för träning, gränsöverskridande behandling eller rutiner för radering. Efter överföringen måste begäranden om åtkomst, rättelse, export eller radering göras via de kanaler som tjänsteoperatören tillhandahåller.

## 4. Gränser för lokal behandling

PalmiAgent driver ingen egen molnserver för modeller som vidarebefordrar, tar emot eller centralt lagrar innehållet i AI-begäranden som beskrivs ovan. I den nuvarande arkitekturen går modellbegäranden från din enhet till den tredjepartsändpunkt du konfigurerar. Appen kan lagra arbetsytor, konversationer och inställningar lokalt enligt vad funktionerna du använder kräver, men att bara öppna appen gör inte att den självständigt samlar in och laddar upp orelaterade personuppgifter. iOS-behörigheter för kontakter, kalendrar, bilder, plats och liknande data begärs separat av systemet när en funktion används; tillståndet i detta meddelande gäller endast att skicka innehåll som du uttryckligen inkluderar i en AI-uppgift till den tredjepartsmodelltjänst som väljs efteråt.
