# Pemberitahuan Privasi dan Layanan AI Pihak Ketiga Palmi

Dokumen untuk dibaca dan disetujui sebelum konfigurasi model pertama kali.

Versi: v26.7 · Tanggal versi: 2026.07.01 · Pembaca: pengguna aplikasi seluler Palmi / PalmiAgent

**Penting:** baca dokumen ini sebelum mengonfigurasi model. Memilih “Saya telah membaca dan setuju” berarti Anda memahami dan mengakui aliran data, batas layanan pihak ketiga, peringatan informasi sensitif, dan tanggung jawab pilihan pengguna yang dijelaskan di sini. Ini tidak berarti Anda telah menerima ketentuan pihak ketiga yang belum ditampilkan kepada Anda. Ketentuan resmi layanan pihak ketiga adalah halaman terkini yang diterbitkan oleh layanan tersebut.

## 1. Tujuan dan Cakupan

Dokumen ini adalah pemberitahuan pengguna Palmi (PalmiAgent) yang ditampilkan sebelum konfigurasi model pertama kali. Dokumen ini menjelaskan kemungkinan aliran data antara aplikasi lokal, layanan model pilihan pengguna, izin sistem, dan alat pihak ketiga, serta meminta pengguna memberikan pernyataan pengakuan secara tegas sebelum melanjutkan.

Dokumen ini bukan kebijakan privasi penyedia model mana pun. Dokumen ini tidak menggantikan ketentuan layanan, kebijakan privasi, perjanjian pengembang, perjanjian pemrosesan data, kebijakan penggunaan yang dapat diterima, lisensi model, atau aturan keselamatan milik penyedia model pihak ketiga, penyedia cloud, agregator model, gateway perusahaan, layanan sistem, atau penerapan lokal mana pun.

Palmi adalah aplikasi agen yang mengutamakan pemrosesan lokal dan antarmuka penghubung model. Model yang Anda pilih, URL Dasar yang Anda masukkan, kunci API yang Anda gunakan, konten yang Anda kirim, serta izin sistem atau alat yang Anda aktifkan akan menentukan apakah data meninggalkan perangkat Anda dan siapa yang memprosesnya.

## 2. Pemrosesan Data Lokal dalam Desain Produk Saat Ini

Dalam desain produk saat ini, Palmi tidak mengoperasikan basis data terpusat di sisi server untuk isi obrolan, file ruang kerja, lampiran, atau kunci API Anda. Proyek, percakapan, file ruang kerja, lampiran, catatan proses, cache, dan preferensi terutama disimpan dalam kontainer aplikasi di perangkat Anda. Kredensial model seharusnya disimpan di Keychain sistem atau penyimpanan kredensial aman yang setara.

OCR lokal, pratinjau file, pembacaan dan penulisan ruang kerja, Python tertanam, cache lokal, pengelolaan percakapan, dan pembersihan data biasanya berjalan di perangkat. Kecuali Anda mengonfigurasi model jarak jauh, pencarian jarak jauh, layanan file jarak jauh, sinkronisasi cloud, berbagi/ekspor, atau fitur pihak ketiga lainnya, materi tersebut biasanya tidak dikirim oleh Palmi sendiri ke server jarak jauh yang dioperasikan Palmi.

Sistem tingkat perangkat, iCloud atau cadangan sistem, diagnostik kerusakan, App Store, pengelolaan perangkat seluler perusahaan, proxy jaringan, VPN, alat keamanan, dan ekspor yang dimulai pengguna dapat memproses data berdasarkan aturan Apple, administrator organisasi, layanan jaringan, atau pihak ketiga pilihan Anda. Palmi tidak mengendalikan proses tingkat sistem atau pilihan pengguna tersebut.

## 3. Kapan Data Dapat Meninggalkan Perangkat

Ketika Anda mengonfigurasi dan menggunakan layanan model jarak jauh, agregator model, endpoint yang dihosting di cloud, gateway perusahaan, atau endpoint kustom yang kompatibel dengan OpenAI, prompt, konteks, ringkasan file, gambar, hasil alat, konfigurasi peran model, potongan instruksi sistem, riwayat percakapan, informasi kesalahan, dan metadata permintaan yang diperlukan dapat dikirim ke layanan tersebut.

Ketika Anda mengaktifkan pencarian web, pembacaan web, peta, email, pesan, telepon, kalender, pengingat, kontak, lokasi, kamera, foto, pengenalan ucapan, notifikasi, Spotlight, perutean sistem, atau kemampuan alat lainnya, data terkait dapat diproses oleh layanan sistem, penyedia pencarian, situs web, layanan akun, lingkungan perusahaan, atau layanan jaringan yang relevan.

Ketika Anda mengimpor, membuka, menyalin, membagikan, mengekspor, mengirim, mengunggah, atau memerintahkan agen untuk melakukan tindakan eksternal pada file, file atau isinya dapat ditulis ke lokasi pilihan Anda, dikirim ke aplikasi, penyedia, atau kontak pilihan Anda, atau masuk ke cache dan log sistem yang relevan.

Pengiriman jaringan biasanya memerlukan konektivitas. Operator jaringan, penyedia DNS, proxy, VPN, gateway, firewall, produk keamanan perusahaan, atau layanan pihak ketiga dapat memproses metadata jaringan berdasarkan aturan mereka sendiri.

## 4. Layanan Model, Endpoint yang Kompatibel dengan OpenAI, dan Batas Tanggung Jawab

Kompatibel dengan OpenAI hanya menjelaskan kemiripan bentuk endpoint, autentikasi, format permintaan, struktur pesan, streaming, atau format panggilan alat. Ini tidak berarti OpenAI mengoperasikan layanan tersebut, dan tidak berarti layanan memiliki aturan keamanan, penyimpanan, pelatihan, penghapusan, transfer lintas negara, sengketa, atau hukum yang sama dengan OpenAI.

Layanan model pihak ketiga, penyedia cloud, agregator model, gateway perusahaan, dan layanan yang dihosting sendiri dapat bertindak sebagai pengendali independen, pemroses, pengendali bersama, penyedia infrastruktur, atau host model. Kebijakan terkini dan perjanjian akun mereka mengatur cara mereka mencatat, menyimpan masukan dan keluaran, melakukan tinjauan keselamatan, menggunakan data untuk pelatihan model, merutekan data ke model upstream, menangani permintaan penghapusan, atau menanggapi permintaan pemerintah maupun regulator.

Palmi tidak dapat memverifikasi untuk Anda kepemilikan endpoint yang Anda masukkan, sumber kunci API, kewenangan akun, wilayah layanan, tanggung jawab penagihan, masa penyimpanan, pengaturan pelatihan, konfigurasi tanpa penyimpanan data, ketentuan perlindungan data perusahaan, atau pemroses model upstream yang sebenarnya. Anda harus memastikan hal-hal ini sebelum menggunakan layanan.

## 5. Konten Sensitif, Materi Perusahaan, dan Data tentang Orang Lain

Anda tidak boleh mengirim kata sandi, kunci API, kunci privat, nomor identitas, kartu bank, informasi kesehatan, informasi anak di bawah umur, lokasi presisi, kontak, catatan obrolan, data pelanggan, rahasia kode sumber, rahasia dagang, riset yang belum diterbitkan, konten yang dilindungi perjanjian kerahasiaan, data yang diatur, atau materi apa pun yang dapat merugikan hak orang lain kecuali Anda memiliki otorisasi, dasar hukum, dan tinjauan keamanan yang memadai.

Jika Anda menggunakan Palmi atas nama perusahaan, sekolah, laboratorium, tim proyek, klien, anggota keluarga, atau pihak ketiga lainnya, Anda harus memastikan bahwa Anda berwenang untuk mengonfigurasi layanan model, mengirim konten terkait, memberikan izin sistem, memanggil alat, mengunggah atau mengekspor file, serta mematuhi persyaratan klasifikasi data, kerahasiaan, kepatuhan, pengadaan, dan persetujuan keamanan organisasi tersebut.

Jika Anda tidak yakin apakah suatu kategori informasi boleh dikirim ke model atau layanan pihak ketiga, jangan mengirimkannya secara default. Pertimbangkan penyamaran informasi sensitif, peringkasan, anonimisasi, pemrosesan lokal, persetujuan internal, atau layanan perusahaan yang memenuhi persyaratan kepatuhan yang berlaku.

## 6. Panggilan Alat, Izin Sistem, dan Tindakan Eksternal

Fitur agen Palmi dapat menyarankan atau memicu pembacaan file, pembuatan file, perubahan ruang kerja, pencarian web, akses ke kalender, pengingat, kontak, lokasi, foto, kamera, ucapan, aplikasi sistem, draf pesan, atau tindakan sistem lainnya. Alat yang berbeda mungkin memerlukan izin iOS, konfirmasi pengguna, otorisasi akun pihak ketiga, atau persetujuan kebijakan organisasi.

Setiap tindakan yang dapat memengaruhi sistem eksternal, orang lain, aset akun, jadwal, status file, pengiriman pesan, pembelian, pembayaran, penyebaran, penghapusan, atau pengungkapan publik harus ditinjau manusia sebelum dilaksanakan. Keluaran model mungkin tidak lengkap, tidak akurat, kedaluwarsa, direkayasa, bias, atau tidak sesuai dengan maksud Anda.

Risiko meningkat secara signifikan jika Anda mengaktifkan persetujuan otomatis, pelaksanaan kelompok, pelaksanaan skrip, otomatisasi web, perutean sistem, atau integrasi alat perusahaan. Gunakan kemampuan ini hanya untuk tugas tepercaya dan lingkungan yang perubahannya dapat dikembalikan.

## 7. Pengelolaan Data Lokal, Penarikan Izin, dan Penghapusan

Anda dapat mengelola data lokal dan data akun pihak ketiga melalui pengelolaan data dalam aplikasi, pengaturan sistem, pengaturan izin iOS, Keychain atau reset kredensial, konsol penyedia, portal akun pihak ketiga, administrator organisasi, tiket penyedia cloud, atau penghapusan instalasi aplikasi.

Membersihkan ruang kerja lokal, cache, preferensi, atau kredensial model Palmi hanya memengaruhi data di perangkat atau salinan yang disimpan Palmi. Ini tidak secara otomatis menghapus data yang sudah dikirim ke layanan model pihak ketiga, penyedia pencarian, situs web, penyedia cloud, agregator, gateway perusahaan, layanan sistem, atau aplikasi lain. Akses, perbaikan, ekspor, penghapusan, penghentian penggunaan untuk pelatihan, kontrol ingatan, atau kontrol penyimpanan log di sisi pihak ketiga harus ditangani berdasarkan kebijakan dan alat akun penyedia tersebut.

Menghapus aplikasi atau mencopot pemasangannya mungkin tetap dipengaruhi cadangan sistem, pengelolaan perangkat perusahaan, log, file yang diekspor, salinan yang dibagikan, masa penyimpanan pihak ketiga, dan kewajiban penyimpanan untuk keperluan hukum.

## 8. Keluaran AI dan Pemberitahuan Risiko Profesional

Keluaran model bukan nasihat hukum, medis, keuangan, investasi, perpajakan, keselamatan teknik, kesehatan mental, ketenagakerjaan, imigrasi, pendidikan, atau nasihat profesional lainnya. Untuk skenario berisiko tinggi atau profesional, konsultasikan dengan profesional yang berkualifikasi dan verifikasi hasilnya secara mandiri.

Model dapat menghasilkan fakta yang salah, kode bermasalah, kutipan keliru, saran keamanan yang menyesatkan, rencana yang tidak dapat dijalankan, kebijakan usang, tautan palsu, atau konten yang tidak pantas. Anda harus mempertimbangkan dengan cermat apakah akan menggunakan, menyebarkan, menjalankan, menyerahkan, atau mengandalkan keluaran model.

Palmi adalah alat dan antarmuka alur kerja. Palmi tidak menjamin bahwa model pihak ketiga, endpoint, alat, sumber pencarian, layanan sistem, atau konfigurasi pengguna selalu tersedia, akurat, aman, patuh, atau sesuai untuk tujuan tertentu.

## 9. Tautan Kebijakan Layanan Model yang Umum

Daftar di bawah mencantumkan kebijakan yang mungkin relevan dengan akses cepat Palmi saat ini, penyedia kompatibel OpenAI yang dipertahankan atau umum digunakan, agregator, dan layanan model kustom. Tautan merupakan akses publik atau konsol resmi yang dikumpulkan untuk versi dokumen ini. Penyedia dapat menampilkan ketentuan berbeda berdasarkan negara atau wilayah, jenis akun, perjanjian perusahaan, produk API, model, jalur hosting, dan penyedia upstream. Sebelum penggunaan, gunakan halaman terkini milik penyedia sebagai acuan.

### Zhipu AI / GLM / Z.ai / BigModel

Salah satu akses cepat penyedia yang saat ini dapat dipilih di Palmi; juga dapat muncul melalui endpoint kustom yang kompatibel dengan OpenAI.

- [BigModel / Platform Terbuka Zhipu](https://open.bigmodel.cn/)
- [Situs resmi Z.ai](https://z.ai/)

Sebelum menggunakan, tinjau ketentuan layanan, kebijakan privasi, ketentuan pengembang, dan ketentuan pemrosesan data terbaru yang ditampilkan di konsol atau alur masuk.

### DeepSeek

Salah satu akses cepat penyedia yang saat ini dapat dipilih di Palmi; juga dapat diakses melalui API resmi, agregator, atau endpoint kustom.

- [Kebijakan Privasi DeepSeek](https://cdn.deepseek.com/policies/en-US/deepseek-privacy-policy.html)
- [Ketentuan Penggunaan DeepSeek](https://cdn.deepseek.com/policies/en-US/deepseek-terms-of-use.html)

### Endpoint Kustom yang Kompatibel dengan OpenAI

URL Dasar, kunci API, dan nama model yang disediakan pengguna. Layanan sebenarnya dapat berupa penyedia resmi, agregator, host cloud, gateway perusahaan, server lokal, atau layanan yang dihosting sendiri.

Kompatibel dengan OpenAI hanya menjelaskan bentuk API; ini tidak berarti OpenAI mengoperasikan endpoint atau aturan privasi, penyimpanan, pelatihan, penghapusan, maupun transfernya sama.

Tinjau kebijakan terkini pemilik endpoint, gateway organisasi, atau sistem yang dihosting sendiri sebelum mengirim data.

### OpenAI / ChatGPT

Dapat muncul melalui endpoint kustom, OpenRouter, Azure OpenAI, atau jalur hosting lainnya.

- [Kebijakan Privasi OpenAI](https://openai.com/policies/privacy-policy/)
- [Ketentuan Penggunaan OpenAI](https://openai.com/policies/terms-of-use/)

### Microsoft Azure OpenAI / Azure AI Foundry

Dapat digunakan melalui sumber daya Azure, akun perusahaan, atau endpoint kustom.

- [Pernyataan Privasi Microsoft](https://www.microsoft.com/en-us/privacy/privacystatement)
- [Data, privasi, dan keamanan Azure OpenAI](https://learn.microsoft.com/en-us/azure/foundry/responsible-ai/openai/data-privacy)

### Alibaba Cloud Model Studio / DashScope / Qwen

Dapat muncul melalui endpoint Alibaba Cloud Model Studio atau DashScope yang kompatibel dengan OpenAI, endpoint kustom, atau agregator.

- [Halaman privasi Alibaba Cloud](https://www.aliyun.com/legal/privacy)
- [Dokumentasi DashScope](https://help.aliyun.com/zh/dashscope/)

Untuk akun perusahaan, tinjau juga ketentuan layanan Alibaba Cloud, perjanjian pemrosesan data, dan aturan khusus wilayah.

### Moonshot AI / Kimi

Dapat muncul melalui API resmi Kimi / Moonshot, endpoint kustom, atau agregator.

- [Platform Terbuka Moonshot AI](https://platform.moonshot.cn/)
- [Situs resmi Kimi](https://kimi.moonshot.cn/)

Gunakan kebijakan privasi, perjanjian layanan, dan ketentuan API terbaru yang ditampilkan pada platform terbuka atau halaman masuk.

### MiniMax / Hailuo / Talkie

Dapat muncul melalui API resmi MiniMax, endpoint kustom, atau agregator.

- [Situs resmi MiniMax](https://www.minimax.io/)
- [Platform terbuka MiniMax](https://platform.minimaxi.com/)

Gunakan kebijakan privasi, perjanjian layanan, dan ketentuan API yang ditampilkan pada platform serta konsol akun.

### Volcengine Ark / Doubao

Dapat muncul melalui endpoint Volcengine Ark yang kompatibel dengan OpenAI, endpoint kustom, atau agregator.

- [Halaman privasi Volcengine](https://www.volcengine.com/docs/6256/64902)
- [Dokumentasi Volcengine Ark](https://www.volcengine.com/docs/82379)

### Tencent Hunyuan

Dapat muncul melalui API Tencent Cloud Hunyuan, endpoint kustom, atau agregator.

- [Pernyataan Privasi Tencent Cloud](https://cloud.tencent.com/document/product/301/11470)
- [Halaman Perjanjian Layanan Tencent Cloud](https://cloud.tencent.com/document/product/301/1967)

### Baidu Qianfan / ERNIE

Dapat muncul melalui endpoint Baidu AI Cloud Qianfan, endpoint kustom, atau agregator.

- [Pusat Privasi Baidu](https://privacy.baidu.com/policy)
- [Dokumentasi Baidu AI Cloud Qianfan](https://cloud.baidu.com/doc/WENXINWORKSHOP/)

### StepFun

Dapat muncul melalui API resmi StepFun, endpoint kustom, atau agregator.

- [Platform terbuka StepFun](https://platform.stepfun.com/)

Gunakan perjanjian layanan, kebijakan privasi, dan ketentuan pengembang yang ditampilkan di konsol StepFun.

### ModelScope

Dapat muncul sebagai akses layanan hosting model atau inferensi.

- [Situs resmi ModelScope](https://modelscope.cn/)

Tinjau ketentuan layanan ModelScope, kebijakan privasi, serta kartu model/lisensi yang relevan.

### SiliconFlow

Dapat muncul sebagai platform agregasi model dan inferensi.

- [Situs resmi SiliconFlow](https://siliconflow.cn/)

Tinjau kebijakan privasi, ketentuan layanan, ketentuan layanan model, dan aturan penyedia model upstream miliknya.

### OpenRouter

Dapat muncul sebagai agregator model global; penyedia model upstream yang dipilih juga dapat memproses masukan dan keluaran.

- [Kebijakan Privasi OpenRouter](https://openrouter.ai/privacy)
- [Ketentuan Layanan OpenRouter](https://openrouter.ai/terms)

Tinjau juga halaman penyedia/data miliknya dan kebijakan penyedia model upstream yang dipilih.

### Ollama

Biasanya digunakan untuk layanan model lokal atau LAN. Jika Anda menghubungkan layanan cloud resmi atau layanan yang dihosting jarak jauh, tinjau kebijakannya secara terpisah.

- [Kebijakan Privasi Ollama](https://ollama.com/privacy)
- [Ketentuan Ollama](https://ollama.com/terms)

### LM Studio

Biasanya digunakan untuk layanan model desktop lokal atau LAN. Jika unduhan jarak jauh, akun, sinkronisasi, atau layanan yang dihosting diaktifkan, tinjau kebijakannya.

- [Privasi LM Studio](https://lmstudio.ai/privacy)
- [Ketentuan LM Studio](https://lmstudio.ai/terms)

### Anthropic / Claude

Palmi saat ini tidak secara langsung melakukan prakonfigurasi protokol native Anthropic, tetapi Claude dapat muncul melalui OpenRouter, gateway perusahaan, atau lapisan kompatibilitas kustom.

- [Kebijakan Privasi Anthropic](https://www.anthropic.com/legal/privacy)
- [Ketentuan dan kebijakan Anthropic](https://www.anthropic.com/legal)

### Google Gemini / Google AI Studio / Vertex AI

Dapat muncul melalui API Google, Vertex AI, agregator, atau gateway perusahaan.

- [Kebijakan Privasi Google](https://policies.google.com/privacy)
- [Pemberitahuan Privasi Google Cloud](https://cloud.google.com/terms/cloud-privacy-notice)
- [Ketentuan tambahan Google AI / Gemini API](https://ai.google.dev/terms)

### Mistral AI

Dapat muncul melalui API resmi Mistral, agregator, atau gateway perusahaan.

- [Pusat Hukum Mistral AI](https://legal.mistral.ai/terms)
- [Kebijakan Privasi Mistral AI](https://legal.mistral.ai/terms/privacy-policy)

### Meta / Llama

Biasanya muncul melalui hosting pihak ketiga, penyedia cloud, agregator, penerapan lokal, atau gateway perusahaan. Lisensi model publik bukan kebijakan privasi layanan hosting.

- [Kebijakan Privasi Meta](https://www.facebook.com/privacy/policy/)
- [Situs resmi Llama](https://www.llama.com/)

Tinjau juga kebijakan host sebenarnya, penyedia cloud, atau pihak yang menerapkan secara lokal.

### xAI / Grok

Dapat muncul melalui API resmi, agregator, atau gateway perusahaan.

- [Kebijakan Privasi xAI](https://x.ai/legal/privacy-policy)
- [Ketentuan Layanan xAI](https://x.ai/legal/terms-of-service)

### Cohere

Dapat muncul melalui API resmi Cohere, agregator, atau gateway perusahaan.

- [Kebijakan Privasi Cohere](https://cohere.com/privacy)
- [Ketentuan Penggunaan Cohere](https://cohere.com/terms-of-use)

### Hugging Face / Inference Providers

Dapat muncul untuk unduhan model, inferensi yang dihosting, Spaces, atau penyedia inferensi pihak ketiga.

- [Kebijakan Privasi Hugging Face](https://huggingface.co/privacy)
- [Ketentuan Layanan Hugging Face](https://huggingface.co/terms-of-service)

Tinjau juga penyedia inferensi sebenarnya dan lisensi model yang relevan.

### Together AI / Fireworks AI / Groq / Replicate / Perplexity / AI21 Labs

Layanan ini dapat muncul melalui endpoint kustom, agregator, SDK, gateway perusahaan, atau jalur hosting upstream.

- [Privasi Together AI](https://www.together.ai/privacy)
- [Privasi Fireworks AI](https://fireworks.ai/privacy)
- [Kebijakan Privasi Groq](https://groq.com/privacy-policy/)
- [Privasi Replicate](https://replicate.com/privacy)
- [Kebijakan Privasi Perplexity](https://www.perplexity.ai/hub/legal/privacy-policy)
- [Kebijakan Privasi AI21 Labs](https://www.ai21.com/privacy-policy)

### iFlytek Spark / Huawei Cloud Pangu / SenseTime / Baichuan / 01.AI / Xiaomi / Meituan dan Penyedia Lainnya

Dapat muncul melalui endpoint kustom, marketplace cloud, gateway perusahaan, penerapan lokal, atau agregator. Aturan yang berlaku berbeda berdasarkan akun, wilayah, bentuk layanan, dan host.

- [Halaman privasi platform terbuka iFlytek](https://www.xfyun.cn/doc/policy/privacy.html)
- [Halaman privasi Huawei Cloud](https://www.huaweicloud.com/declaration/sa_prp.html)
- [Halaman kebijakan privasi Xiaomi](https://privacy.mi.com/all/zh_CN/)

Untuk Meituan LongCat, Baichuan, 01.AI, SenseTime, dan layanan serupa, gunakan kebijakan terbaru yang ditampilkan di situs resmi, platform terbuka, atau konsol layanan model penyedia.

Jika layanan tidak tercantum di atas, terapkan aturan yang sama: pastikan kepemilikan endpoint, entitas layanan, penyedia upstream, wilayah yang berlaku, kebijakan pencatatan dan pelatihan, metode penghapusan dan ekspor, biaya, serta batas kepatuhan.

## 10. Pernyataan Pengguna

1. Saya memahami bahwa Palmi adalah aplikasi agen yang mengutamakan pemrosesan lokal dan antarmuka penghubung model, serta bahwa desain saat ini tidak menggunakan basis data terpusat di sisi server yang dioperasikan Palmi untuk isi obrolan, file ruang kerja, lampiran, atau kunci API.
2. Saya memahami bahwa ketika saya mengonfigurasi atau menggunakan model pihak ketiga, agregator, sumber pencarian, layanan sistem, gateway perusahaan, endpoint lokal atau jarak jauh yang dihosting sendiri, atau alat lain, konten yang saya pilih untuk dikirim dan metadata yang diperlukan dapat diproses oleh layanan tersebut.
3. Saya memahami bahwa penyimpanan data pihak ketiga, penggunaan untuk pelatihan, perutean upstream, transfer lintas negara, permintaan penghapusan, keamanan akun, biaya, dan penanganan sengketa diatur oleh kebijakan terkini pihak ketiga itu dan perjanjian saya dengannya.
4. Saya akan mengirim informasi pribadi, materi perusahaan, data pelanggan, file, gambar, kode, atau konten lain hanya ketika saya memiliki hak, kewenangan, dan dasar kepatuhan yang memadai, serta akan menggunakan tinjauan manusia dalam konteks berisiko tinggi.
5. Jika saya tidak menyetujui pemberitahuan ini atau belum memastikan kebijakan penyedia yang saya pilih, saya dapat menghentikan konfigurasi model atau kembali dan mengubah pilihan saya.

Dokumen ini ditujukan untuk pemberitahuan pengguna dalam produk dan pengakuan operasional. Dokumen ini bukan nasihat hukum individual untuk pengguna, organisasi, industri, atau yurisdiksi mana pun. Sebelum rilis resmi, pengajuan ke toko aplikasi, peluncuran komersial, atau penggunaan dalam industri yang diatur, disarankan peninjauan oleh profesional yang berkualifikasi di yurisdiksi terkait.
