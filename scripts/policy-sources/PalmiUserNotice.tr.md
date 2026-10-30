# Palmi Gizlilik ve Üçüncü Taraf Yapay Zekâ Hizmetleri Bildirimi

İlk model yapılandırmasından önce okunup onaylanacak belge

Sürüm: v26.7  
Sürüm tarihi: 2026.07.01  
Hedef kitle: Palmi / PalmiAgent mobil uygulaması kullanıcıları

**Önemli:** Model yapılandırmadan önce bu belgeyi okuyun. “Okudum ve kabul ediyorum” seçeneğini belirlemek, burada açıklanan veri akışlarını, üçüncü taraf hizmetlerin sınırlarını, hassas bilgilere ilişkin uyarıları ve kullanıcı seçiminden doğan sorumlulukları anladığınız ve onayladığınız anlamına gelir. Size gösterilmeyen herhangi bir üçüncü taraf koşulunu kabul ettiğiniz anlamına gelmez. Üçüncü taraf hizmetlerin resmî koşulları, bu hizmetlerin yayımladığı güncel sayfalardır.

## 1. Amaç ve Kapsam

Bu belge, ilk model yapılandırmasından önce gösterilen Palmi (PalmiAgent) kullanıcı bildirimidir. Yerel uygulama, kullanıcının seçtiği model hizmetleri, sistem izinleri ve üçüncü taraf araçlar arasındaki olası veri akışlarını açıklar ve devam etmeden önce kullanıcıdan açık onay ister.

Bu belge, herhangi bir model sağlayıcısının gizlilik politikası değildir. Herhangi bir üçüncü taraf model sağlayıcısının, bulut sağlayıcısının, model toplayıcısının, kurumsal ağ geçidinin, sistem hizmetinin veya yerel dağıtımın hizmet koşullarının, gizlilik politikasının, geliştirici sözleşmesinin, veri işleme sözleşmesinin, kabul edilebilir kullanım politikasının, model lisansının veya güvenlik kurallarının yerine geçmez.

Palmi, yerel işlemeyi önceliklendiren bir ajan uygulaması ve model bağlantı arayüzüdür. Seçtiğiniz model, girdiğiniz Temel URL, kullandığınız API anahtarı, gönderdiğiniz içerik ve etkinleştirdiğiniz sistem izinleri veya araçlar, verilerin cihazınızdan çıkıp çıkmayacağını ve kimin tarafından işleneceğini belirler.

## 2. Geçerli Ürün Tasarımında Yerel Veri İşleme

Geçerli ürün tasarımında Palmi, sohbet içerikleriniz, çalışma alanı dosyalarınız, ekleriniz veya API anahtarlarınız için kendine ait merkezi bir sunucu tarafı veritabanı işletmez. Projeler, sohbetler, çalışma alanı dosyaları, ekler, çalışma kayıtları, önbellekler ve tercihler ağırlıklı olarak cihazınızdaki uygulama kapsayıcısında saklanır. Model kimlik bilgileri, sistem Keychain'inde veya eşdeğer bir güvenli kimlik bilgisi deposunda saklanmalıdır.

Yerel OCR, dosya önizlemesi, çalışma alanında okuma ve yazma, gömülü Python, yerel önbellekler, sohbet yönetimi ve veri temizleme genellikle cihazda çalışır. Uzak model, uzak arama, uzak dosya hizmeti, bulut eşitleme, paylaşma/dışa aktarma veya başka bir üçüncü taraf özelliği yapılandırmadığınız sürece bu materyaller normalde Palmi'nin kendisi tarafından Palmi'nin işlettiği uzak bir sunucuya gönderilmez.

Cihaz düzeyindeki sistemler, iCloud veya sistem yedeklemesi, çökme tanılaması, App Store, kurumsal mobil cihaz yönetimi, ağ vekilleri, VPN'ler, güvenlik araçları ve kullanıcının başlattığı dışa aktarmalar; Apple'ın, bir kuruluş yöneticisinin, ağ hizmetinin veya seçtiğiniz bir üçüncü tarafın kuralları kapsamında verileri işleyebilir. Palmi, sistem düzeyindeki veya kullanıcı tarafından seçilen bu süreçleri denetlemez.

## 3. Veriler Ne Zaman Cihazdan Çıkabilir?

Uzak model hizmeti, model toplayıcısı, bulutta barındırılan uç nokta, kurumsal ağ geçidi veya özel OpenAI uyumlu uç nokta yapılandırıp kullandığınızda; istemler, bağlam, dosya özetleri, görüntüler, araç sonuçları, model rolü yapılandırması, sistem talimatı parçaları, sohbet geçmişi, hata bilgileri ve gerekli istek meta verileri bu hizmete gönderilebilir.

Web araması, web okuma, haritalar, posta, mesajlar, telefon, takvim, anımsatıcılar, kişiler, konum, kamera, fotoğraflar, konuşma tanıma, bildirimler, Spotlight, sistem yönlendirmesi veya başka araç yeteneklerini etkinleştirdiğinizde ilgili veriler; ilgili sistem hizmeti, arama sağlayıcısı, web sitesi, hesap hizmeti, kurumsal ortam veya ağ hizmeti tarafından işlenebilir.

Bir dosyayı içe aktardığınızda, açtığınızda, kopyaladığınızda, paylaştığınızda, dışa aktardığınızda, gönderdiğinizde, yüklediğinizde veya bir ajana dosya üzerinde haricî bir eylem gerçekleştirmesi talimatını verdiğinizde; dosya veya içeriği seçtiğiniz bir konuma yazılabilir, seçtiğiniz bir uygulamaya, sağlayıcıya veya kişiye gönderilebilir ya da ilgili sistemin önbelleklerine ve günlüklerine girebilir.

Ağ üzerinden iletim normalde bağlantı gerektirir. Ağ operatörleri, DNS sağlayıcıları, vekiller, VPN'ler, ağ geçitleri, güvenlik duvarları, kurumsal güvenlik ürünleri veya üçüncü taraf hizmetler, ağ meta verilerini kendi kuralları kapsamında işleyebilir.

## 4. Model Hizmetleri, OpenAI Uyumlu Uç Noktalar ve Sorumluluk Sınırları

OpenAI uyumlu ifadesi yalnızca uç nokta yapısı, kimlik doğrulama, istek biçimi, mesaj yapısı, akış veya araç çağrısı biçimindeki benzerliği tanımlar. Hizmeti OpenAI'ın işlettiği anlamına gelmez; hizmetin OpenAI ile aynı güvenlik, saklama, eğitim, silme, sınır ötesi aktarım, uyuşmazlık veya hukuk kurallarına sahip olduğu anlamına da gelmez.

Üçüncü taraf model hizmetleri, bulut sağlayıcıları, model toplayıcıları, kurumsal ağ geçitleri ve kendi barındırılan hizmetler; bağımsız veri sorumlusu, veri işleyen, ortak veri sorumlusu, altyapı sağlayıcısı veya model barındırıcısı olarak hareket edebilir. Verileri nasıl günlüğe kaydettikleri, girdileri ve çıktıları nasıl sakladıkları, güvenlik incelemesini nasıl yaptıkları, verileri model eğitimi için nasıl kullandıkları, üst hizmet modellerine nasıl yönlendirdikleri, silme isteklerini nasıl ele aldıkları veya kamu makamlarının ya da düzenleyicilerin taleplerine nasıl yanıt verdikleri, güncel politikalarına ve hesap sözleşmelerine tabidir.

Palmi; girdiğiniz uç noktanın sahibini, API anahtarının kaynağını, hesap yetkisini, hizmet bölgesini, faturalandırma sorumluluğunu, saklama süresini, eğitim ayarını, sıfır veri saklama yapılandırmasını, kurumsal veri koruma koşullarını veya üst hizmetteki gerçek model işleyicisini sizin adınıza doğrulayamaz. Kullanmadan önce bu konuları teyit etmelisiniz.

## 5. Hassas İçerik, Kurumsal Materyaller ve Başkalarıyla İlgili Veriler

Yeterli yetkilendirmeye, hukuki dayanağa ve güvenlik incelemesine sahip olmadıkça parolaları, API anahtarlarını, özel anahtarları, kimlik numaralarını, banka kartı bilgilerini, sağlık bilgilerini, reşit olmayanlara ilişkin bilgileri, kesin konumu, kişileri, sohbet kayıtlarını, müşteri verilerini, kaynak koddaki gizli bilgileri, ticari sırları, yayımlanmamış araştırmaları, gizlilik sözleşmesiyle korunan içeriği, düzenlemeye tabi verileri veya başka bir kişinin haklarına zarar verebilecek herhangi bir materyali göndermemelisiniz.

Palmi'yi bir şirket, okul, laboratuvar, proje ekibi, müşteri, aile üyesi veya başka bir üçüncü taraf adına kullanıyorsanız; model hizmetlerini yapılandırmaya, ilgili içeriği göndermeye, sistem izinlerini vermeye, araçları çağırmaya, dosyaları yüklemeye veya dışa aktarmaya yetkili olduğunuzu ve o kuruluşun veri sınıflandırma, gizlilik, uyumluluk, satın alma ve güvenlik onayı gereksinimlerine uyduğunuzu teyit etmelisiniz.

Bir bilgi kategorisinin modele veya üçüncü taraf hizmete gönderilip gönderilemeyeceğinden emin değilseniz varsayılan olarak göndermeyin. Hassas kısımları çıkarmayı, özetlemeyi, anonimleştirmeyi, yerel işlemeyi, kurum içi onay almayı veya geçerli uyumluluk gereksinimlerini karşılayan kurumsal bir hizmet kullanmayı değerlendirin.

## 6. Araç Çağrıları, Sistem İzinleri ve Haricî Eylemler

Palmi'nin ajan özellikleri; dosya okuma, dosya üretme, çalışma alanında değişiklik yapma, web arama, takvime, anımsatıcılara, kişilere, konuma, fotoğraflara, kameraya, konuşmaya, sistem uygulamalarına, mesaj taslaklarına erişme veya başka sistem eylemlerini önerebilir ya da tetikleyebilir. Farklı araçlar iOS izinleri, kullanıcı onayı, üçüncü taraf hesap yetkilendirmesi veya kuruluş politikası onayı gerektirebilir.

Haricî bir sistemi, başka bir kişiyi, hesap varlıklarını, programları, dosya durumunu, mesaj göndermeyi, satın almaları, ödemeleri, dağıtımları, silmeyi veya kamuya açıklamayı etkileyebilecek her eylem, yürütülmeden önce bir insan tarafından incelenmelidir. Model çıktıları eksik, hatalı, güncelliğini yitirmiş, uydurma, yanlı veya niyetinizle tutarsız olabilir.

Otomatik onayları, toplu yürütmeyi, betik yürütmeyi, web otomasyonunu, sistem yönlendirmesini veya kurumsal araç entegrasyonlarını etkinleştirirseniz risk önemli ölçüde artar. Bu yetenekleri yalnızca güvenilir görevlerde ve işlemlerin geri alınabildiği ortamlarda kullanın.

## 7. Yerel Veri Yönetimi, İzni Geri Çekme ve Silme

Yerel verileri ve üçüncü taraf hesap verilerini; uygulama içi veri yönetimi, sistem ayarları, iOS izin ayarları, Keychain veya kimlik bilgilerini sıfırlama, sağlayıcı konsolları, üçüncü taraf hesap portalları, kuruluş yöneticileri, bulut sağlayıcısı destek talepleri veya uygulamayı kaldırma yoluyla yönetebilirsiniz.

Palmi'nin yerel çalışma alanını, önbelleklerini, tercihlerini veya model kimlik bilgilerini temizlemek yalnızca cihazdaki verileri ya da Palmi'nin tuttuğu kopyaları etkiler. Üçüncü taraf model hizmetlerine, arama sağlayıcılarına, web sitelerine, bulut sağlayıcılarına, toplayıcılara, kurumsal ağ geçitlerine, sistem hizmetlerine veya diğer uygulamalara zaten gönderilmiş verileri otomatik silmez. Üçüncü taraf tarafındaki erişim, düzeltme, dışa aktarma, silme, eğitimde kullanımı durdurma, hafıza denetimleri veya günlük saklama denetimleri, o sağlayıcının politikası ve hesap araçları kapsamında ele alınmalıdır.

Uygulamayı silme veya kaldırma; sistem yedeklerinden, kurumsal cihaz yönetiminden, günlüklerden, dışa aktarılmış dosyalardan, paylaşılan kopyalardan, üçüncü taraf saklama sürelerinden ve yasal saklama yükümlülüklerinden yine de etkilenebilir.

## 8. Yapay Zekâ Çıktısı ve Mesleki Risk Bildirimi

Model çıktısı; hukuk, tıp, finans, yatırım, vergi, mühendislik güvenliği, ruh sağlığı, istihdam, göçmenlik, eğitim veya başka bir alanda mesleki tavsiye değildir. Yüksek riskli veya mesleki durumlarda yetkin bir uzmana danışın ve sonucu bağımsız olarak doğrulayın.

Modeller yanlış olgular, hatalı kod, yanlış atıflar, yanıltıcı güvenlik tavsiyeleri, yürütülemeyen planlar, güncel olmayan politikalar, sahte bağlantılar veya uygunsuz içerik üretebilir. Model çıktısını kullanmaya, dağıtmaya, yürütmeye, sunmaya veya ona güvenmeye dikkatle karar vermelisiniz.

Palmi bir araç ve iş akışı arayüzüdür. Herhangi bir üçüncü taraf modelin, uç noktanın, aracın, arama kaynağının, sistem hizmetinin veya kullanıcı yapılandırmasının her zaman kullanılabilir, doğru, güvenli, uyumlu veya belirli bir amaca uygun olduğunu garanti etmez.

## 9. Yaygın Model Hizmetlerinin Politika Bağlantıları

Aşağıdaki liste; Palmi'nin güncel hızlı erişim seçenekleri, yapılandırmaları korunmuş veya yaygın OpenAI uyumlu sağlayıcılar, toplayıcılar ve özel model hizmetleriyle ilgili olabilecek politika bağlantılarını içerir. Bağlantılar, bu belge sürümü için derlenen herkese açık girişler veya resmî konsol girişleridir. Sağlayıcılar; ülke veya bölgeye, hesap türüne, kurumsal sözleşmeye, API ürününe, modele, barındırma yoluna ve üst hizmet sağlayıcısına göre farklı koşullar gösterebilir. Kullanmadan önce sağlayıcının güncel sayfasını esas alın.

### Zhipu AI / GLM / Z.ai / BigModel

Palmi'nin şu anda seçilebilen hızlı sağlayıcı seçeneklerinden biridir; özel bir OpenAI uyumlu uç nokta üzerinden de görünebilir.

- BigModel / Zhipu Açık Platformu: https://open.bigmodel.cn/
- Z.ai resmî girişi: https://z.ai/

Kullanmadan önce konsolda veya giriş akışında gösterilen en güncel hizmet koşullarını, gizlilik politikasını, geliştirici koşullarını ve veri işleme koşullarını inceleyin.

### DeepSeek

Palmi'nin şu anda seçilebilen hızlı sağlayıcı seçeneklerinden biridir; resmî API, bir toplayıcı veya özel uç nokta üzerinden de erişilebilir.

- DeepSeek Gizlilik Politikası: https://cdn.deepseek.com/policies/en-US/deepseek-privacy-policy.html
- DeepSeek Kullanım Koşulları: https://cdn.deepseek.com/policies/en-US/deepseek-terms-of-use.html

### Özel OpenAI uyumlu uç nokta

Kullanıcının sağladığı Temel URL, API anahtarı ve model adıdır. Gerçek hizmet resmî bir sağlayıcı, toplayıcı, bulut barındırıcısı, kurumsal ağ geçidi, yerel sunucu veya kendi barındırılan hizmet olabilir.

OpenAI uyumlu ifadesi yalnızca API yapısını tanımlar; uç noktayı OpenAI'ın işlettiği veya gizlilik, saklama, eğitim, silme ya da aktarım kurallarının aynı olduğu anlamına gelmez.

Veri göndermeden önce uç nokta sahibinin, kuruluş ağ geçidinin veya kendi barındırılan sistemin güncel politikasını inceleyin.

### OpenAI / ChatGPT

Özel bir uç nokta, OpenRouter, Azure OpenAI veya başka bir barındırma yolu üzerinden görünebilir.

- OpenAI Gizlilik Politikası: https://openai.com/policies/privacy-policy/
- OpenAI Kullanım Koşulları: https://openai.com/policies/terms-of-use/

### Microsoft Azure OpenAI / Azure AI Foundry

Azure kaynağı, kurumsal hesap veya özel uç nokta üzerinden kullanılabilir.

- Microsoft Gizlilik Bildirimi: https://www.microsoft.com/en-us/privacy/privacystatement
- Azure OpenAI verileri, gizlilik ve güvenlik: https://learn.microsoft.com/en-us/azure/foundry/responsible-ai/openai/data-privacy

### Alibaba Cloud Model Studio / DashScope / Qwen

Alibaba Cloud Model Studio veya DashScope OpenAI uyumlu uç noktaları, özel uç noktalar veya toplayıcılar üzerinden görünebilir.

- Alibaba Cloud gizlilik girişi: https://www.aliyun.com/legal/privacy
- DashScope belge girişi: https://help.aliyun.com/zh/dashscope/

Kurumsal hesaplarda Alibaba Cloud hizmet koşullarını, veri işleme sözleşmelerini ve bölgeye özgü kuralları da inceleyin.

### Moonshot AI / Kimi

Kimi / Moonshot resmî API'si, özel uç nokta veya toplayıcı üzerinden görünebilir.

- Moonshot AI Açık Platformu: https://platform.moonshot.cn/
- Kimi resmî girişi: https://kimi.moonshot.cn/

Açık platformda veya giriş sayfasında gösterilen en güncel gizlilik politikasını, hizmet sözleşmesini ve API koşullarını esas alın.

### MiniMax / Hailuo / Talkie

MiniMax resmî API'si, özel uç nokta veya toplayıcı üzerinden görünebilir.

- MiniMax resmî sitesi: https://www.minimax.io/
- MiniMax açık platformu: https://platform.minimaxi.com/

Platformda ve hesap konsolunda gösterilen gizlilik politikasını, hizmet sözleşmesini ve API koşullarını esas alın.

### Volcengine Ark / Doubao

Volcengine Ark OpenAI uyumlu uç noktaları, özel uç nokta veya toplayıcı üzerinden görünebilir.

- Volcengine gizlilik girişi: https://www.volcengine.com/docs/6256/64902
- Volcengine Ark belge girişi: https://www.volcengine.com/docs/82379

### Tencent Hunyuan

Tencent Cloud Hunyuan API'leri, özel uç nokta veya toplayıcı üzerinden görünebilir.

- Tencent Cloud Gizlilik Bildirimi: https://cloud.tencent.com/document/product/301/11470
- Tencent Cloud Hizmet Sözleşmesi girişi: https://cloud.tencent.com/document/product/301/1967

### Baidu Qianfan / ERNIE

Baidu AI Cloud Qianfan uç noktaları, özel uç nokta veya toplayıcı üzerinden görünebilir.

- Baidu Gizlilik Merkezi: https://privacy.baidu.com/policy
- Baidu AI Cloud Qianfan belge girişi: https://cloud.baidu.com/doc/WENXINWORKSHOP/

### StepFun

StepFun resmî API'si, özel uç nokta veya toplayıcı üzerinden görünebilir.

- StepFun açık platformu: https://platform.stepfun.com/

StepFun konsolunda gösterilen hizmet sözleşmesini, gizlilik politikasını ve geliştirici koşullarını esas alın.

### ModelScope

Model barındırma veya çıkarım hizmeti seçeneği olarak görünebilir.

- ModelScope resmî girişi: https://modelscope.cn/

ModelScope hizmet koşullarını, gizlilik politikasını ve ilgili model kartını/lisansını inceleyin.

### SiliconFlow

Model toplama ve çıkarım platformu olarak görünebilir.

- SiliconFlow resmî girişi: https://siliconflow.cn/

Gizlilik politikasını, hizmet koşullarını, model hizmeti koşullarını ve üst hizmetteki model sağlayıcılarının kurallarını inceleyin.

### OpenRouter

Küresel model toplayıcısı olarak görünebilir; seçilen üst hizmet model sağlayıcısı da girdileri ve çıktıları işleyebilir.

- OpenRouter Gizlilik Politikası: https://openrouter.ai/privacy
- OpenRouter Hizmet Koşulları: https://openrouter.ai/terms

Sağlayıcı/veri sayfalarını ve seçilen üst hizmet model sağlayıcısının politikasını da inceleyin.

### Ollama

Genellikle yerel veya LAN model hizmetleri için kullanılır. Resmî bulut hizmetlerine veya uzaktan barındırılan hizmetlere bağlanırsanız bunların politikalarını ayrıca inceleyin.

- Ollama Gizlilik Politikası: https://ollama.com/privacy
- Ollama Koşulları: https://ollama.com/terms

### LM Studio

Genellikle yerel masaüstü veya LAN model hizmetleri için kullanılır. Uzak indirmeler, hesaplar, eşitleme veya barındırılan hizmetler etkinleştirilirse politikalarını inceleyin.

- LM Studio Gizlilik: https://lmstudio.ai/privacy
- LM Studio Koşulları: https://lmstudio.ai/terms

### Anthropic / Claude

Palmi şu anda Anthropic'in yerel protokolünü doğrudan önceden yapılandırmaz; ancak Claude, OpenRouter, kurumsal ağ geçidi veya özel uyumluluk katmanı üzerinden görünebilir.

- Anthropic Gizlilik Politikası: https://www.anthropic.com/legal/privacy
- Anthropic koşulları ve politikaları: https://www.anthropic.com/legal

### Google Gemini / Google AI Studio / Vertex AI

Google API'leri, Vertex AI, toplayıcı veya kurumsal ağ geçidi üzerinden görünebilir.

- Google Gizlilik Politikası: https://policies.google.com/privacy
- Google Cloud Gizlilik Bildirimi: https://cloud.google.com/terms/cloud-privacy-notice
- Google AI / Gemini API ek koşulları: https://ai.google.dev/terms

### Mistral AI

Mistral resmî API'si, toplayıcı veya kurumsal ağ geçidi üzerinden görünebilir.

- Mistral AI Hukuk Merkezi: https://legal.mistral.ai/terms
- Mistral AI Gizlilik Politikası: https://legal.mistral.ai/terms/privacy-policy

### Meta / Llama

Genellikle üçüncü taraf barındırma, bulut sağlayıcısı, toplayıcı, yerel dağıtım veya kurumsal ağ geçidi üzerinden görünür. Herkese açık bir model lisansı, barındırma hizmetinin gizlilik politikası değildir.

- Meta Gizlilik Politikası: https://www.facebook.com/privacy/policy/
- Llama resmî sitesi: https://www.llama.com/

Gerçek barındırıcının, bulut sağlayıcısının veya yerel dağıtımı yapan tarafın politikasını da inceleyin.

### xAI / Grok

Resmî API, toplayıcı veya kurumsal ağ geçidi üzerinden görünebilir.

- xAI Gizlilik Politikası: https://x.ai/legal/privacy-policy
- xAI Hizmet Koşulları: https://x.ai/legal/terms-of-service

### Cohere

Cohere resmî API'si, toplayıcı veya kurumsal ağ geçidi üzerinden görünebilir.

- Cohere Gizlilik Politikası: https://cohere.com/privacy
- Cohere Kullanım Koşulları: https://cohere.com/terms-of-use

### Hugging Face / Inference Providers

Model indirmeleri, barındırılan çıkarım, Spaces veya üçüncü taraf çıkarım sağlayıcıları için görünebilir.

- Hugging Face Gizlilik Politikası: https://huggingface.co/privacy
- Hugging Face Hizmet Koşulları: https://huggingface.co/terms-of-service

Gerçek çıkarım sağlayıcısını ve ilgili model lisansını da inceleyin.

### Together AI / Fireworks AI / Groq / Replicate / Perplexity / AI21 Labs

Bu hizmetler özel uç noktalar, toplayıcılar, SDK'lar, kurumsal ağ geçitleri veya üst hizmet barındırma yolları üzerinden görünebilir.

- Together AI Gizlilik: https://www.together.ai/privacy
- Fireworks AI Gizlilik: https://fireworks.ai/privacy
- Groq Gizlilik Politikası: https://groq.com/privacy-policy/
- Replicate Gizlilik: https://replicate.com/privacy
- Perplexity Gizlilik Politikası: https://www.perplexity.ai/hub/legal/privacy-policy
- AI21 Labs Gizlilik Politikası: https://www.ai21.com/privacy-policy

### iFlytek Spark / Huawei Cloud Pangu / SenseTime / Baichuan / 01.AI / Xiaomi / Meituan ve diğer sağlayıcılar

Özel uç nokta, bulut pazaryeri, kurumsal ağ geçidi, yerel dağıtım veya toplayıcı üzerinden görünebilir. Geçerli kurallar hesaba, bölgeye, hizmet biçimine ve barındırıcıya göre değişir.

- iFlytek açık platform gizlilik girişi: https://www.xfyun.cn/doc/policy/privacy.html
- Huawei Cloud gizlilik girişi: https://www.huaweicloud.com/declaration/sa_prp.html
- Xiaomi gizlilik politikası girişi: https://privacy.mi.com/all/zh_CN/

Meituan LongCat, Baichuan, 01.AI, SenseTime ve benzeri hizmetlerde sağlayıcının resmî sitesinde, açık platformunda veya model hizmeti konsolunda gösterilen en güncel politikayı esas alın.

Bir hizmet yukarıda listelenmemişse aynı kuralı uygulayın: uç nokta sahipliğini, hizmeti sunan tüzel kişiyi, üst hizmet sağlayıcısını, geçerli bölgeyi, günlük tutma ve eğitim politikasını, silme ve dışa aktarma yöntemlerini, maliyetleri ve uyumluluk sınırlarını teyit edin.

## 10. Kullanıcı Onayı

1. Palmi'nin yerel işlemeyi önceliklendiren bir ajan uygulaması ve model bağlantı arayüzü olduğunu; geçerli tasarımın sohbet içerikleri, çalışma alanı dosyaları, ekler veya API anahtarları için Palmi'nin işlettiği merkezi bir sunucu tarafı veritabanı kullanmadığını anlıyorum.
2. Bir üçüncü taraf modeli, toplayıcıyı, arama kaynağını, sistem hizmetini, kurumsal ağ geçidini, yerel veya uzaktan kendi barındırılan uç noktayı ya da başka bir aracı yapılandırdığımda veya kullandığımda, göndermeyi seçtiğim içeriğin ve gerekli meta verilerin bu hizmet tarafından işlenebileceğini anlıyorum.
3. Üçüncü tarafın veri saklamasının, eğitim amaçlı kullanımının, üst hizmetlere yönlendirmesinin, sınır ötesi aktarımının, silme isteklerinin, hesap güvenliğinin, maliyetlerinin ve uyuşmazlık çözümünün, o üçüncü tarafın güncel politikalarına ve onunla yaptığım sözleşmeye tabi olduğunu anlıyorum.
4. Kişisel bilgileri, kurumsal materyalleri, müşteri verilerini, dosyaları, görüntüleri, kodu veya başka içerikleri yalnızca yeterli haklara, yetkiye ve uyumluluk dayanağına sahip olduğumda göndereceğim; yüksek riskli bağlamlarda insan incelemesi kullanacağım.
5. Bu bildirimi kabul etmezsem veya seçtiğim sağlayıcının politikasını teyit etmediysem model yapılandırmasını durdurabileceğimi ya da geri dönüp seçimimi değiştirebileceğimi biliyorum.

Bu belge, ürün içinde kullanıcıyı bilgilendirmek ve işleyişe ilişkin onay almak amacıyla hazırlanmıştır. Herhangi bir kullanıcı, kuruluş, sektör veya yargı alanı için kişiye özel hukuki danışmanlık değildir. Resmî yayımdan, uygulama mağazasına gönderimden, ticari kullanıma sunmadan veya düzenlemeye tabi sektörlerde kullanmadan önce ilgili yargı alanlarında yetkin uzmanlar tarafından incelenmesi önerilir.
