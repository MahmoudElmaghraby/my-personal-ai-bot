FROM dart:stable

WORKDIR /app

# نسخ الملفات وتحميل المكتبات
COPY . .
RUN dart pub get

# تعريف البوابة (Port) عشان منصة Back4App تشوفها
EXPOSE 8080

# تشغيل البوت مباشرة لتفادي أي مشاكل في شهادات الأمان (SSL)
CMD ["dart", "run", "bin/life_assistant_bot.dart"]