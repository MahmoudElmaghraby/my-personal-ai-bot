import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:teledart/teledart.dart';
import 'package:teledart/telegram.dart';
import 'package:dotenv/dotenv.dart';

// ==========================================
// 1. كلاس لتخطي مشاكل شهادات الأمان (SSL) في السيرفرات السحابية
// ==========================================
class MyHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback =
          (X509Certificate cert, String host, int port) => true;
  }
}

late String botToken;
late String geminiApiKey;
late String notionToken;
late String tasksDbId;
late String financesDbId;
late String projectsDbId;
late String knowledgeDbId;

// ==========================================
// 2. دالة التعامل مع Gemini
// ==========================================
Future<String?> analyzeMessageWithGemini(String userMessage) async {
  final url = Uri.parse(
    'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=$geminiApiKey',
  );

  // جلب تاريخ اليوم ديناميكياً لتسهيل حساب المواعيد على الذكاء الاصطناعي
  final String todayDate = DateTime.now().toString().split(' ')[0];

  final prompt =
      '''
  أنت مساعد شخصي ذكي لمهندس برمجيات اسمه محمود. 
  مهمتك تحليل رسالته وتصنيفها إلى واحدة من 6 فئات، واستخراج البيانات.
  علماً بأن تاريخ اليوم هو ($todayDate).

  يجب أن يكون الإخراج بصيغة JSON فقط، التزم بهذا الهيكل تماماً:
  1. Task: {"type": "Task", "data": {"name": "...", "category": "...", "deadline": "yyyy-mm-dd", "details": "..."}}
  2. Finance: {"type": "Finance", "data": {"name": "...", "amount": 0, "dueDate": "yyyy-mm-dd", "details": "..."}}
  3. Project: {"type": "Project", "data": {"name": "...", "targetDate": "yyyy-mm-dd", "details": "..."}}
  4. Knowledge: {"type": "Knowledge", "data": {"title": "...", "topic": "...", "details": "..."}}
  5. Query: {"type": "Query", "data": {"target": "Finance"}} (الـ target يجب أن يكون: Task, Finance, Project, أو Knowledge)
  6. Chat: {"type": "Chat", "data": {"response": "ردك هنا"}}

  رسالة محمود: "$userMessage"
  ''';

  final body = jsonEncode({
    "contents": [
      {
        "parts": [
          {"text": prompt},
        ],
      },
    ],
    "generationConfig": {"responseMimeType": "application/json"},
  });

  try {
    final response = await http.post(
      url,
      headers: {'Content-Type': 'application/json'},
      body: body,
    );
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      if (data['candidates'] == null || data['candidates'].isEmpty) return null;
      return data['candidates'][0]['content']['parts'][0]['text'].trim();
    }
    print('Gemini API Error: ${response.body}');
    return null;
  } catch (e) {
    print('Exception in Gemini: $e');
    return null;
  }
}

// ==========================================
// 3. دالة الإدخال إلى Notion
// ==========================================
Future<bool> sendToNotion(String jsonString) async {
  try {
    final Map<String, dynamic> parsedJson = jsonDecode(jsonString);
    final String type = parsedJson['type'];
    final Map<String, dynamic> data = parsedJson['data'];

    String targetDbId = '';
    Map<String, dynamic> properties = {};

    bool hasValidDate(dynamic dateVal) {
      if (dateVal == null) return false;
      String dateStr = dateVal.toString().trim();
      return dateStr.isNotEmpty && dateStr.toLowerCase() != 'null';
    }

    if (type == 'Task') {
      targetDbId = tasksDbId;
      properties = {
        "Name": {
          "title": [
            {
              "text": {"content": data['name'] ?? 'بدون اسم'},
            },
          ],
        },
        "Category": {
          "select": {"name": data['category'] ?? 'عام'},
        },
      };
      if (hasValidDate(data['deadline']))
        properties["Date"] = {
          "date": {"start": data['deadline']},
        };
    } else if (type == 'Finance') {
      targetDbId = financesDbId;
      properties = {
        "Name": {
          "title": [
            {
              "text": {"content": data['name'] ?? 'بدون اسم'},
            },
          ],
        },
        "Amount": {"number": data['amount'] ?? 0},
      };
      if (hasValidDate(data['dueDate']))
        properties["Due Date"] = {
          "date": {"start": data['dueDate']},
        };
    } else if (type == 'Project') {
      targetDbId = projectsDbId;
      properties = {
        "Project Name": {
          "title": [
            {
              "text": {"content": data['name'] ?? 'بدون اسم'},
            },
          ],
        },
      };
      if (hasValidDate(data['targetDate']))
        properties["Date"] = {
          "date": {"start": data['targetDate']},
        };
    } else if (type == 'Knowledge') {
      targetDbId = knowledgeDbId;
      properties = {
        "Title": {
          "title": [
            {
              "text": {"content": data['title'] ?? 'بدون عنوان'},
            },
          ],
        },
        "Topic": {
          "select": {"name": data['topic'] ?? 'عام'},
        },
      };
    }

    Map<String, dynamic> requestBody = {
      "parent": {"database_id": targetDbId},
      "properties": properties,
    };

    if (data['details'] != null &&
        data['details'].toString().trim().isNotEmpty) {
      requestBody["children"] = [
        {
          "object": "block",
          "type": "paragraph",
          "paragraph": {
            "rich_text": [
              {
                "type": "text",
                "text": {"content": data['details']},
              },
            ],
          },
        },
      ];
    }

    final url = Uri.parse('https://api.notion.com/v1/pages');
    final response = await http.post(
      url,
      headers: {
        'Authorization': 'Bearer $notionToken',
        'Content-Type': 'application/json',
        'Notion-Version': '2022-06-28',
      },
      body: jsonEncode(requestBody),
    );
    return response.statusCode == 200;
  } catch (e) {
    print('Notion Send Exception: $e');
    return false;
  }
}

// ==========================================
// 4. دالة الاستعلام (قراءة البيانات من Notion)
// ==========================================
Future<String> queryNotionDatabase(String targetType) async {
  String targetDbId = '';
  String headerText = '';
  String safeTarget = targetType.trim().toLowerCase();

  if (safeTarget.contains('task')) {
    targetDbId = tasksDbId;
    headerText = '📋 مهامك الحالية:\n\n';
  } else if (safeTarget.contains('finance')) {
    targetDbId = financesDbId;
    headerText = '💰 الأقساط والالتزامات المسجلة:\n\n';
  } else if (safeTarget.contains('project')) {
    targetDbId = projectsDbId;
    headerText = '🚀 مشاريعك المسجلة:\n\n';
  } else if (safeTarget.contains('knowledge')) {
    targetDbId = knowledgeDbId;
    headerText = '🧠 الأفكار والمعلومات المسجلة:\n\n';
  } else {
    return 'لم أتمكن من تحديد الجدول المطلوب.';
  }

  final url = Uri.parse(
    'https://api.notion.com/v1/databases/$targetDbId/query',
  );

  try {
    final response = await http.post(
      url,
      headers: {
        'Authorization': 'Bearer $notionToken',
        'Notion-Version': '2022-06-28',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({}),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      final List results = data['results'];
      if (results.isEmpty) return 'الجدول ده فاضي حالياً يا هندسة.';

      String output = headerText;
      for (var item in results) {
        final props = item['properties'];

        if (safeTarget.contains('finance')) {
          final nameList = props['Name']?['title'] as List?;
          final name = (nameList != null && nameList.isNotEmpty)
              ? nameList[0]['text']['content']
              : 'بدون اسم';
          final amount = props['Amount']?['number'] ?? 0;
          final date = props['Due Date']?['date']?['start'] ?? 'بدون تاريخ';
          output += '🔹 $name\n   المبلغ: $amount | الاستحقاق: $date\n\n';
        } else if (safeTarget.contains('task')) {
          final nameList = props['Name']?['title'] as List?;
          final name = (nameList != null && nameList.isNotEmpty)
              ? nameList[0]['text']['content']
              : 'بدون اسم';
          final category = props['Category']?['select']?['name'] ?? 'عام';
          final date = props['Date']?['date']?['start'] ?? 'بدون تاريخ';
          output += '🔹 $name\n   التصنيف: $category | الموعد: $date\n\n';
        } else if (safeTarget.contains('project')) {
          final nameList = props['Project Name']?['title'] as List?;
          final name = (nameList != null && nameList.isNotEmpty)
              ? nameList[0]['text']['content']
              : 'بدون اسم';
          final date = props['Date']?['date']?['start'] ?? 'بدون تاريخ';
          output += '🔹 $name\n   الموعد المستهدف: $date\n\n';
        } else if (safeTarget.contains('knowledge')) {
          final nameList = props['Title']?['title'] as List?;
          final name = (nameList != null && nameList.isNotEmpty)
              ? nameList[0]['text']['content']
              : 'بدون اسم';
          final topic = props['Topic']?['select']?['name'] ?? 'عام';
          output += '🔹 $name\n   المجال: $topic\n\n';
        }
      }
      return output;
    } else {
      return 'حصلت مشكلة في قراءة البيانات من Notion.';
    }
  } catch (e) {
    return 'إيرور في الاتصال بـ Notion: $e';
  }
}

// ==========================================
// 5. التشغيل الرئيسي (Main)
// ==========================================
void main() async {
  // تفعيل تخطي الأمان
  HttpOverrides.global = MyHttpOverrides();

  // تحميل المتغيرات بطريقة هجينة (تقرأ من ملف .env لوكال، ومن السيرفر لو مرفوعة)
  final env = DotEnv(includePlatformEnvironment: true)..load();

  // قراءة المتغيرات مع تنظيفها من أي مسافات زائدة
  botToken = (env['TELEGRAM_BOT_TOKEN'] ?? '').trim();
  geminiApiKey = (env['GEMINI_API_KEY'] ?? '').trim();
  notionToken = (env['NOTION_TOKEN'] ?? '').trim();
  tasksDbId = (env['TASKS_DB_ID'] ?? '').trim();
  financesDbId = (env['FINANCES_DB_ID'] ?? '').trim();
  projectsDbId = (env['PROJECTS_DB_ID'] ?? '').trim();
  knowledgeDbId = (env['KNOWLEDGE_DB_ID'] ?? '').trim();

  if (botToken.isEmpty || geminiApiKey.isEmpty || notionToken.isEmpty) {
    print('❌ خطأ: تأكد من تعيين جميع المتغيرات السرية!');
    return;
  }

  // تشغيل السيرفر الوهمي (لحماية البوت من الإغلاق على السيرفرات السحابية)
  try {
    final portStr = Platform.environment['PORT'] ?? '8080';
    final port = int.tryParse(portStr) ?? 8080;

    final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    print('🌐 Web Server running on port $port...');

    server.listen(
      (HttpRequest request) {
        request.response
          ..write('Bot is alive and running 24/7!')
          ..close();
      },
      onError: (error) {
        print('⚠️ Ignored server error: $error');
      },
    );
  } catch (e) {
    print('⚠️ Could not start dummy server: $e');
  }

  // تشغيل بوت تليجرام
  try {
    print('⏳ جاري الاتصال بسيرفرات تليجرام...');
    final me = await Telegram(
      botToken,
    ).getMe().timeout(const Duration(seconds: 15));
    final username = me.username;

    final teledart = TeleDart(botToken, Event(username!));
    teledart.start();
    print(
      '🚀 البوت شغال دلوقتي وجاهز يقرأ ويكتب يا هندسة! (معرف البوت: @$username)',
    );

    teledart.onCommand('start').listen((message) {
      message.reply(
        'أهلاً بيك يا محمود! 🫡\nأنا جاهز أرتبلك حياتك وأجاوبك على أي بيانات مسجلها.',
      );
    });

    teledart.onMessage(entityType: '*').listen((message) async {
      final userText = message.text;
      if (userText == null) return;

      final processingMsg = await message.reply('جاري التحليل... 🧠');
      final jsonResult = await analyzeMessageWithGemini(userText);

      if (jsonResult != null) {
        try {
          final parsedJson = jsonDecode(jsonResult);
          final type = parsedJson['type'];

          if (type == 'Chat') {
            await teledart.editMessageText(
              parsedJson['data']['response'],
              chatId: processingMsg.chat.id,
              messageId: processingMsg.messageId,
            );
          } else if (type == 'Query') {
            String target = parsedJson['data']['target'];
            String retrievedData = await queryNotionDatabase(target);
            await teledart.editMessageText(
              retrievedData,
              chatId: processingMsg.chat.id,
              messageId: processingMsg.messageId,
            );
          } else {
            bool success = await sendToNotion(jsonResult);
            if (success) {
              await teledart.editMessageText(
                'تم التسجيل بنجاح في Notion! ✅\n\nنوع الإدخال: $type',
                chatId: processingMsg.chat.id,
                messageId: processingMsg.messageId,
              );
            } else {
              await teledart.editMessageText(
                'الذكاء الاصطناعي حلل الرسالة، بس حصلت مشكلة في الحفظ في Notion ❌.',
                chatId: processingMsg.chat.id,
                messageId: processingMsg.messageId,
              );
            }
          }
        } catch (e) {
          await teledart.editMessageText(
            'حصلت مشكلة في قراءة البيانات 😅',
            chatId: processingMsg.chat.id,
            messageId: processingMsg.messageId,
          );
        }
      } else {
        await teledart.editMessageText(
          'مشكلة في الاتصال بالذكاء الاصطناعي 😅',
          chatId: processingMsg.chat.id,
          messageId: processingMsg.messageId,
        );
      }
    });
  } catch (e) {
    print('❌ خطأ في الاتصال بتليجرام: $e');
  }
}
