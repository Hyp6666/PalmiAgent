# Üçüncü Taraf Yapay Zekâ Hizmetlerine Veri Aktarımı Bildirimi

Sürüm: v26.11  Sürüm tarihi: 2026.11.01

PalmiAgent, yerel işlemeyi önceliklendiren bir yapay zekâ aracıdır. Sohbetlerinizi, eklerinizi veya araç sonuçlarınızı alan, saklayan ya da analiz eden bir bulut model sunucusu işletmez; siz bir işlem yapmadan veya ilgili izni vermeden bu bilgileri yapay zekâ işlemesi için bağımsız olarak toplayıp yüklemez. Uygulama, yalnızca sonraki adımda bir model yapılandırıp yapay zekâ isteği başlattığınızda ve ilgili içeriği seçtiğinizde, isteği yerine getirmek için gereken içeriği bizzat seçtiğiniz üçüncü taraf yapay zekâ model hizmetine gönderir.

## 1. Gönderilebilecek Veriler

1. Etkin olarak girdiğiniz mesajlar, istemler ve talimatlar ile modelin geçerli isteği anlamak ve tamamlamak için ihtiyaç duyduğu önceki mesajlar, sohbet bağlamı ve görev durumu; uygulamayı açmak, bir ekranda kalmak veya uygulamayı arka plana almak tek başına ilgisiz sohbetlerin yüklenmesine neden olmaz;
2. Geçerli göreve açıkça eklediğiniz görüntüler, belgeler ve diğer dosyalar; modele bu ekleri anlamasında yardımcı olmak için kullanılan çıkarılmış metinler, OCR sonuçları, dosya biçimi bilgileri veya gerekli özetler buna dahildir; isteğe eklemediğiniz diğer yerel dosyalar bu nedenle gönderilmez;
3. İlgili iOS iznini ayrıca verip aracı açıkça çağırdıktan sonra geçerli göreve dahil edilen takvim, anımsatıcı, kişi, konum, fotoğraf veya diğer araç sonuçları; sistem izni vermek tek başına verilerin iletilmesine onay değildir ve yalnızca geçerli yapay zekâ isteğinde gerçekten kullanılan sonuçlar gönderilebilir;
4. Geçerli isteği düzenlemek, tamamlamak veya kurtarmak için gereken sistem talimatları, araç tanımları ve sonuçları, model tanımlayıcıları, üretim parametreleri ve teknik bilgiler; bu bilgiler, üçüncü taraf modelin başlattığınız görevi doğru işlemesini sağlamak için kullanılır.

## 2. Alıcılar

Alıcı, PalmiAgent değil, sonraki adımda bizzat seçtiğiniz veya girip onayladığınız üçüncü taraf yapay zekâ model hizmeti ve API uç noktası işletmecisidir. Uygulama bu bildirimde belirli bir hizmeti önceden seçmez, önermez veya ima etmez; henüz tamamlamadığınız bir yapılandırmayı da göstermez. Yapılandırmanın ardından, başlattığınız yapay zekâ isteğindeki içerik ağ üzerinden bu hizmetin işletmecisinin denetlediği arayüze iletilir. İlgili tüzel işletmeci, sunucu bölgesi ve verileri gerçekten işleyen taraf, sonuçta seçtiğiniz hizmete ve koşullara bağlıdır. Hizmetin kimliğini, gizlilik politikasını veya veri işleme kurallarını doğrulayamıyorsanız ya da bunlara güvenmiyorsanız yapılandırmasını tamamlamayın ve içerik göndermeyin.

## 3. Amaç

İçerik yalnızca etkin olarak başlattığınız istekleri işlemek için gönderilir. Buna model yanıtları oluşturmak, seçtiğiniz görüntü veya dosyaları anlamak, istediğiniz Ajan görevlerini yerine getirmek ve isteği tamamlamak için gereken bağlamı korumak dahildir. Üçüncü taraf hizmet, verileri kendi gizlilik politikası, koşulları ve hesap ayarları uyarınca kaydedebilir, inceleyebilir, saklayabilir, üst işlemcilere yönlendirebilir veya silebilir. PalmiAgent bu üçüncü tarafın saklama süresini, eğitim amaçlı kullanımını, sınır ötesi işlemesini veya silme uygulamalarını belirleyemez. İletimden sonra verilere erişme, verileri düzeltme, dışa aktarma veya silme istekleri hizmet işletmecisinin sağladığı kanallardan yapılmalıdır.

## 4. Yerel İşleme Sınırları

PalmiAgent, yukarıda açıklanan yapay zekâ isteği içeriğini aktarmak, almak veya merkezi olarak saklamak için kendi bulut model sunucusunu işletmez. Geçerli mimaride model istekleri cihazınızdan yapılandırdığınız üçüncü taraf uç noktasına gider. Uygulama, kullandığınız özelliklerin gerektirdiği şekilde çalışma alanlarını, sohbetleri ve ayarları yerel olarak saklayabilir; ancak uygulamayı açmak tek başına ilgisiz kişisel bilgileri bağımsız olarak toplamasına ve yüklemesine neden olmaz. Kişiler, takvimler, fotoğraflar, konum ve benzeri veriler için iOS izinleri, özellik kullanıldığında sistem tarafından ayrıca istenir. Bu bildirimdeki izin yalnızca bir yapay zekâ görevine açıkça eklediğiniz içeriğin daha sonra seçilecek üçüncü taraf model hizmetine gönderilmesi içindir.
