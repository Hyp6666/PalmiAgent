# Pemberitahuan Pengiriman Data ke Layanan AI Pihak Ketiga

Versi: v26.11  Tanggal versi: 2026.11.01

PalmiAgent adalah alat AI yang mengutamakan pemrosesan lokal. Aplikasi ini tidak mengoperasikan server model cloud yang menerima, menyimpan, atau menganalisis obrolan, lampiran, maupun hasil alat Anda, dan tidak secara mandiri mengumpulkan serta mengunggah informasi tersebut untuk pemrosesan AI ketika Anda belum melakukan tindakan atau memberikan izin terkait. Hanya setelah Anda mengonfigurasi model pada langkah berikutnya, memulai permintaan AI, dan memilih konten terkait, aplikasi mengirim konten yang diperlukan untuk menjalankan permintaan itu ke layanan model AI pihak ketiga yang Anda pilih sendiri.

## 1. Data yang Mungkin Dikirim

1. Pesan, prompt, dan instruksi yang Anda masukkan secara aktif, beserta pesan sebelumnya, konteks percakapan, dan status tugas yang diperlukan model untuk memahami serta menyelesaikan permintaan saat ini; sekadar membuka aplikasi, tetap berada pada suatu layar, atau memindahkan aplikasi ke latar belakang tidak dengan sendirinya mengunggah obrolan yang tidak terkait;
2. Gambar, dokumen, dan file lain yang secara tegas Anda tambahkan ke tugas saat ini, termasuk teks hasil ekstraksi, hasil OCR, informasi format file, atau ringkasan yang diperlukan agar model memahami lampiran tersebut; file lokal lain yang tidak Anda tambahkan ke permintaan tidak dikirim untuk alasan ini;
3. Hasil kalender, pengingat, kontak, lokasi, foto, atau alat lain yang disertakan dalam tugas saat ini setelah Anda memberikan izin iOS yang berlaku secara terpisah dan secara tegas memanggil alat; pemberian izin sistem bukan persetujuan untuk mengirim data, dan hanya hasil yang benar-benar digunakan oleh permintaan AI saat ini yang dapat dikirim;
4. Instruksi sistem, definisi dan hasil alat, pengenal model, parameter pembuatan, serta informasi teknis yang diperlukan untuk mengatur, menyelesaikan, atau memulihkan permintaan saat ini; informasi ini digunakan agar model pihak ketiga dapat memproses tugas yang Anda mulai dengan benar.

## 2. Penerima

Penerimanya adalah layanan model AI pihak ketiga dan operator endpoint API yang Anda pilih sendiri atau masukkan dan konfirmasi pada langkah berikutnya, bukan PalmiAgent. Aplikasi tidak memilih, merekomendasikan, atau menyiratkan layanan tertentu dalam pemberitahuan ini, serta tidak menampilkan konfigurasi yang belum Anda selesaikan. Setelah konfigurasi, konten dalam permintaan AI yang Anda mulai dikirim melalui jaringan ke antarmuka yang dikendalikan operator layanan tersebut. Operator hukum, wilayah server, dan pemroses data sebenarnya bergantung pada layanan serta ketentuan yang akhirnya Anda pilih. Jika Anda tidak dapat memverifikasi atau tidak memercayai identitas, kebijakan privasi, atau aturan penanganan data layanan itu, jangan selesaikan konfigurasinya atau mengirim konten kepadanya.

## 3. Tujuan

Konten dikirim hanya untuk memproses permintaan yang Anda mulai secara aktif, termasuk membuat jawaban model, memahami gambar atau file pilihan Anda, melakukan tugas Agen yang Anda minta, dan mempertahankan konteks yang diperlukan untuk menyelesaikan permintaan tersebut. Layanan pihak ketiga dapat mencatat, meninjau, menyimpan, meneruskan ke pemroses upstream, atau menghapus data berdasarkan kebijakan privasi, ketentuan, dan pengaturan akun miliknya. PalmiAgent tidak dapat menentukan masa penyimpanan, penggunaan untuk pelatihan, pemrosesan lintas negara, atau praktik penghapusan pihak ketiga tersebut. Setelah pengiriman, permintaan untuk mengakses, memperbaiki, mengekspor, atau menghapus data harus dilakukan melalui saluran yang disediakan operator layanan itu.

## 4. Batas Pemrosesan Lokal

PalmiAgent tidak mengoperasikan server model cloud sendiri untuk meneruskan, menerima, atau menyimpan secara terpusat konten permintaan AI yang dijelaskan di atas. Dalam arsitektur saat ini, permintaan model dikirim dari perangkat Anda ke endpoint pihak ketiga yang Anda konfigurasikan. Aplikasi dapat menyimpan ruang kerja, percakapan, dan pengaturan secara lokal sesuai kebutuhan fitur yang Anda gunakan, tetapi sekadar membuka aplikasi tidak membuatnya secara mandiri mengumpulkan serta mengunggah informasi pribadi yang tidak terkait. Izin iOS untuk kontak, kalender, foto, lokasi, dan data serupa diminta secara terpisah oleh sistem saat fitur digunakan; izin dalam pemberitahuan ini hanya berlaku untuk mengirim konten yang secara tegas Anda sertakan dalam tugas AI ke layanan model pihak ketiga yang dipilih setelahnya.
