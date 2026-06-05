import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:teledart/teledart.dart';
import 'package:teledart/telegram.dart';
import 'package:dotenv/dotenv.dart';

// هنعرف المتغيرات كـ late عشان نقرأها جوه الـ main
late String botToken;
late String geminiApiKey;
late String notionToken;
late String tasksDbId;
late String financesDbId;
late String projectsDbId;
late String knowledgeDbId;

// دالة التعامل مع Gemini (معدلة لتفادي أخطاء الـ JSON في الدردشة)
Future<String?> analyzeMessageWithGemini(String userMessage) async {
  final url = Uri.parse(
    'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=$geminiApiKey',
  );

  final prompt =
      '''
  أنت مساعد شخصي ذكي لمهندس برمجيات اسمه محمود. 
  مهمتك تحليل رسالة محمود وتصنيفها إلى واحدة من 6 فئات، واستخراج البيانات في صيغة JSON فقط (بدون أي نصوص إضافية أو Markdown).
  
  علماً بأن تاريخ اليوم هو (الجمعة 5 يونيو 2026).

  الفئات والتنسيق المطلوب للـ JSON:
  1. إدخال مهمة (Task): {"type": "Task", "data": {"name": "...", "category": "...", "deadline": "yyyy-mm-dd", "details": "..."}}
  2. إدخال التزام مالي (Finance): {"type": "Finance", "data": {"name": "...", "amount": 0, "dueDate": "yyyy-mm-dd", "details": "..."}}
  3. إدخال مشروع (Project): {"type": "Project", "data": {"name": "...", "targetDate": "yyyy-mm-dd", "details": "..."}}
  4. إدخال معرفة أو فكرة (Knowledge): {"type": "Knowledge", "data": {"title": "...", "topic": "...", "details": "..."}}
  5. الاستعلام (Query): {"type": "Query", "data": {"target": "..."}}
  6. دردشة عامة (Chat): {"type": "Chat", "data": {"response": "ردك هنا"}}

  ملاحظة تقنية هامة جداً: في حالة مسار الدردشة (Chat)، تأكد تماماً أن النص بداخل "response" آمن كـ JSON. قم بالهروب (Escape) لأي علامات تنصيص مزدوجة هكذا \\" وتجنب الأسطر الجديدة الحقيقية، استخدم \\n بدلاً منها.

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
  });

  try {
    final response = await http.post(
      url,
      headers: {'Content-Type': 'application/json'},
      body: body,
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);

      // التأكد من وجود رد فعلي لتفادي الـ Null Error
      if (data['candidates'] == null || data['candidates'].isEmpty) {
        print('❌ Gemini returned empty candidates. Response: ${response.body}');
        return null;
      }

      String result = data['candidates'][0]['content']['parts'][0]['text'];
      return result.replaceAll('```json', '').replaceAll('```', '').trim();
    } else {
      print(
        '❌ Gemini API HTTP Error: ${response.statusCode} - ${response.body}',
      );
      return null;
    }
  } catch (e) {
    print('❌ Exception in Gemini API call: $e');
    return null;
  }
}

// دالة الإرسال إلى Notion (تم تعديلها لكتابة التفاصيل داخل الصفحة)
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
        properties["Target Date"] = {
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

    // بناء الـ Request Body
    Map<String, dynamic> requestBody = {
      "parent": {"database_id": targetDbId},
      "properties": properties,
    };

    // لو الذكاء الاصطناعي لقى تفاصيل، هنحطها كمحتوى (Block) جوه الصفحة
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

    if (response.statusCode != 200) print('Notion API Error: ${response.body}');
    return response.statusCode == 200;
  } catch (e) {
    print('Notion Exception: $e');
    return false;
  }
}

// ==========================================
// دالة الاستعلام الجديدة (RAG / Data Retrieval)
// ==========================================
Future<String> queryNotionDatabase(String targetType) async {
  String targetDbId = '';
  String headerText = '';

  if (targetType == 'Task') {
    targetDbId = tasksDbId;
    headerText = '📋 مهامك الحالية:\n\n';
  } else if (targetType == 'Finance') {
    targetDbId = financesDbId;
    headerText = '💰 الأقساط والالتزامات المسجلة:\n\n';
  } else if (targetType == 'Project') {
    targetDbId = projectsDbId;
    headerText = '🚀 مشاريعك المسجلة:\n\n';
  } else if (targetType == 'Knowledge') {
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
      // نرسل body فارغ لجلب كل البيانات (ممكن لاحقاً نضيف فلاتر للتاريخ)
      body: jsonEncode({}),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      final List results = data['results'];

      if (results.isEmpty) return 'الجدول ده فاضي حالياً يا هندسة.';

      String output = headerText;

      // Parsing الداتا المعقدة بتاعت Notion بأمان
      for (var item in results) {
        final props = item['properties'];

        if (targetType == 'Finance') {
          final nameList = props['Name']?['title'] as List?;
          final name = (nameList != null && nameList.isNotEmpty)
              ? nameList[0]['text']['content']
              : 'بدون اسم';
          final amount = props['Amount']?['number'] ?? 0;
          final date = props['Due Date']?['date']?['start'] ?? 'بدون تاريخ';
          output += '🔹 $name\n   المبلغ: $amount | الاستحقاق: $date\n\n';
        } else if (targetType == 'Task') {
          final nameList = props['Name']?['title'] as List?;
          final name = (nameList != null && nameList.isNotEmpty)
              ? nameList[0]['text']['content']
              : 'بدون اسم';
          final category = props['Category']?['select']?['name'] ?? 'عام';
          final date = props['Date']?['date']?['start'] ?? 'بدون تاريخ';
          output += '🔹 $name\n   التصنيف: $category | الموعد: $date\n\n';
        } else if (targetType == 'Project') {
          final nameList = props['Project Name']?['title'] as List?;
          final name = (nameList != null && nameList.isNotEmpty)
              ? nameList[0]['text']['content']
              : 'بدون اسم';
          final date = props['Target Date']?['date']?['start'] ?? 'بدون تاريخ';
          output += '🔹 $name\n   الموعد المستهدف: $date\n\n';
        } else if (targetType == 'Knowledge') {
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
      return 'حصلت مشكلة في قراءة البيانات من Notion. (كود الخطأ: ${response.statusCode})';
    }
  } catch (e) {
    return 'إيرور في الاتصال بـ Notion: $e';
  }
}

void main() async {
  // 1. تحميل المتغيرات من البيئة أو من ملف .env محلياً
  final env = DotEnv(includePlatformEnvironment: true)..load();

  botToken = env['TELEGRAM_BOT_TOKEN'] ?? '';
  geminiApiKey = env['GEMINI_API_KEY'] ?? '';
  notionToken = env['NOTION_TOKEN'] ?? '';
  tasksDbId = env['TASKS_DB_ID'] ?? '';
  financesDbId = env['FINANCES_DB_ID'] ?? '';
  projectsDbId = env['PROJECTS_DB_ID'] ?? '';
  knowledgeDbId = env['KNOWLEDGE_DB_ID'] ?? '';

  if (botToken.isEmpty || geminiApiKey.isEmpty || notionToken.isEmpty) {
    print('❌ خطأ: تأكد من تعيين جميع المتغيرات في ملف .env بشكل صحيح!');
    return;
  }

  final username = (await Telegram(botToken).getMe()).username;
  final teledart = TeleDart(botToken, Event(username!));

  teledart.start();
  print('البوت شغال دلوقتي وجاهز يقرأ ويكتب يا هندسة... 🚀');

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

        // 1. مسار الدردشة
        if (type == 'Chat') {
          await teledart.editMessageText(
            parsedJson['data']['response'],
            chatId: processingMsg.chat.id,
            messageId: processingMsg.messageId,
          );
        }
        // 2. مسار الاستعلام (قراءة من Notion)
        else if (type == 'Query') {
          String target = parsedJson['data']['target'];
          String retrievedData = await queryNotionDatabase(target);

          await teledart.editMessageText(
            retrievedData,
            chatId: processingMsg.chat.id,
            messageId: processingMsg.messageId,
          );
        }
        // 3. مسار التنظيم (إدخال إلى Notion)
        else {
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
        print('JSON Parsing Error: $e');
        await teledart.editMessageText(
          'حصلت مشكلة في قراءة البيانات المرجعة من الذكاء الاصطناعي 😅',
          chatId: processingMsg.chat.id,
          messageId: processingMsg.messageId,
        );
      }
    } else {
      await teledart.editMessageText(
        'حصلت مشكلة في الاتصال بالذكاء الاصطناعي 😅',
        chatId: processingMsg.chat.id,
        messageId: processingMsg.messageId,
      );
    }
  });
}
