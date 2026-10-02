import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const OfflineExpenseApp());
}

// ==========================================
// 1. DATA MODELS
// ==========================================

class Category {
  final int? id;
  final String name;
  final int iconCodePoint;
  final int colorValue;
  final double monthlyBudget;
  final bool isExpense;

  const Category({
    this.id,
    required this.name,
    required this.iconCodePoint,
    required this.colorValue,
    this.monthlyBudget = 0.0,
    this.isExpense = true,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'icon_code_point': iconCodePoint,
        'color_value': colorValue,
        'monthly_budget': monthlyBudget,
        'is_expense': isExpense ? 1 : 0,
      };

  factory Category.fromMap(Map<String, dynamic> map) => Category(
        id: map['id'] as int?,
        name: map['name'] as String,
        iconCodePoint: map['icon_code_point'] as int,
        colorValue: map['color_value'] as int,
        monthlyBudget: (map['monthly_budget'] as num).toDouble(),
        isExpense: (map['is_expense'] as int) == 1,
      );
}

class ExpenseTransaction {
  final int? id;
  final String title;
  final double amount;
  final DateTime date;
  final int categoryId;
  final bool isExpense;
  final String paymentMethod;
  final String? note;

  const ExpenseTransaction({
    this.id,
    required this.title,
    required this.amount,
    required this.date,
    required this.categoryId,
    this.isExpense = true,
    this.paymentMethod = 'Cash',
    this.note,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'title': title,
        'amount': amount,
        'date': date.millisecondsSinceEpoch,
        'category_id': categoryId,
        'is_expense': isExpense ? 1 : 0,
        'payment_method': paymentMethod,
        'note': note,
      };

  factory ExpenseTransaction.fromMap(Map<String, dynamic> map) =>
      ExpenseTransaction(
        id: map['id'] as int?,
        title: map['title'] as String,
        amount: (map['amount'] as num).toDouble(),
        date: DateTime.fromMillisecondsSinceEpoch(map['date'] as int),
        categoryId: map['category_id'] as int,
        isExpense: (map['is_expense'] as int) == 1,
        paymentMethod: map['payment_method'] as String? ?? 'Cash',
        note: map['note'] as String?,
      );
}

enum ChatSender { user, assistant, system }

class ChatMessage {
  final int? id;
  final ChatSender sender;
  final String content;
  final DateTime timestamp;

  const ChatMessage({
    this.id,
    required this.sender,
    required this.content,
    required this.timestamp,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'sender': sender.name,
        'content': content,
        'timestamp': timestamp.millisecondsSinceEpoch,
      };

  factory ChatMessage.fromMap(Map<String, dynamic> map) => ChatMessage(
        id: map['id'] as int?,
        sender: ChatSender.values.firstWhere(
          (e) => e.name == map['sender'],
          orElse: () => ChatSender.system,
        ),
        content: map['content'] as String,
        timestamp: DateTime.fromMillisecondsSinceEpoch(map['timestamp'] as int),
      );
}

// ==========================================
// 2. UNIVERSAL STORAGE (SQLITE ON ANDROID, WEB STORE ON IPHONE)
// ==========================================

class AppDatabase {
  static final AppDatabase instance = AppDatabase._init();
  static Database? _database;

  // Web Fallback Data
  static final Map<String, String> _webSettings = {
    'monthly_budget': '20000.0',
    'currency': '₱',
    'dark_mode': '0',
  };

  static final List<Category> _webCategories = [
    const Category(id: 1, name: 'Food & Dining', iconCodePoint: 0xe532, colorValue: 0xFFFF7043, monthlyBudget: 5000.0, isExpense: true),
    const Category(id: 2, name: 'Groceries', iconCodePoint: 0xe3ab, colorValue: 0xFF66BB6A, monthlyBudget: 4000.0, isExpense: true),
    const Category(id: 3, name: 'Transportation', iconCodePoint: 0xe1d7, colorValue: 0xFF42A5F5, monthlyBudget: 2500.0, isExpense: true),
    const Category(id: 4, name: 'Utilities & Bills', iconCodePoint: 0xe56c, colorValue: 0xFFFFA726, monthlyBudget: 3500.0, isExpense: true),
    const Category(id: 5, name: 'Entertainment', iconCodePoint: 0xe40f, colorValue: 0xFFAB47BC, monthlyBudget: 2000.0, isExpense: true),
    const Category(id: 6, name: 'Health & Care', iconCodePoint: 0xe3e3, colorValue: 0xFFEF5350, monthlyBudget: 1500.0, isExpense: true),
    const Category(id: 7, name: 'Salary / Income', iconCodePoint: 0xe041, colorValue: 0xFF26A69A, monthlyBudget: 0.0, isExpense: false),
  ];

  static final List<ExpenseTransaction> _webTransactions = [];
  static final List<ChatMessage> _webChatMessages = [];

  AppDatabase._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('expense_tracker_v3.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final fullPath = p.join(dbPath, filePath);
    return await openDatabase(fullPath, version: 1, onCreate: _createDB);
  }

  Future<void> _createDB(Database db, int version) async {
    await db.execute('CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
    await db.execute('''
      CREATE TABLE categories (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        icon_code_point INTEGER NOT NULL,
        color_value INTEGER NOT NULL,
        monthly_budget REAL NOT NULL DEFAULT 0.0,
        is_expense INTEGER NOT NULL DEFAULT 1
      )
    ''');
    await db.execute('''
      CREATE TABLE transactions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        amount REAL NOT NULL,
        date INTEGER NOT NULL,
        category_id INTEGER NOT NULL,
        is_expense INTEGER NOT NULL DEFAULT 1,
        payment_method TEXT NOT NULL,
        note TEXT,
        FOREIGN KEY (category_id) REFERENCES categories (id) ON DELETE CASCADE
      )
    ''');
    await db.execute('''
      CREATE TABLE chat_messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sender TEXT NOT NULL,
        content TEXT NOT NULL,
        timestamp INTEGER NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX idx_tx_date ON transactions(date)');

    await db.insert('settings', {'key': 'monthly_budget', 'value': '20000.0'});
    await db.insert('settings', {'key': 'currency', 'value': '₱'});
    await db.insert('settings', {'key': 'dark_mode', 'value': '0'});

    for (final cat in _webCategories) {
      await db.insert('categories', cat.toMap());
    }
  }

  Future<String> getSetting(String key, String defaultValue) async {
    if (kIsWeb) return _webSettings[key] ?? defaultValue;
    final db = await database;
    final res = await db.query('settings', where: 'key = ?', whereArgs: [key]);
    if (res.isNotEmpty) return res.first['value'] as String;
    return defaultValue;
  }

  Future<void> setSetting(String key, String value) async {
    if (kIsWeb) {
      _webSettings[key] = value;
      return;
    }
    final db = await database;
    await db.insert('settings', {'key': key, 'value': value}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<int> insertTransaction(ExpenseTransaction tx) async {
    if (kIsWeb) {
      final newTx = ExpenseTransaction(
        id: _webTransactions.length + 1,
        title: tx.title,
        amount: tx.amount,
        date: tx.date,
        categoryId: tx.categoryId,
        isExpense: tx.isExpense,
        paymentMethod: tx.paymentMethod,
        note: tx.note,
      );
      _webTransactions.insert(0, newTx);
      return newTx.id!;
    }
    final db = await database;
    return await db.insert('transactions', tx.toMap());
  }

  Future<int> updateTransaction(ExpenseTransaction tx) async {
    if (kIsWeb) {
      final index = _webTransactions.indexWhere((t) => t.id == tx.id);
      if (index != -1) _webTransactions[index] = tx;
      return 1;
    }
    final db = await database;
    return await db.update('transactions', tx.toMap(), where: 'id = ?', whereArgs: [tx.id]);
  }

  Future<int> deleteTransaction(int id) async {
    if (kIsWeb) {
      _webTransactions.removeWhere((t) => t.id == id);
      return 1;
    }
    final db = await database;
    return await db.delete('transactions', where: 'id = ?', whereArgs: [id]);
  }

  Future<List<ExpenseTransaction>> getAllTransactions({int limit = 200}) async {
    if (kIsWeb) return List.from(_webTransactions);
    final db = await database;
    final maps = await db.query('transactions', orderBy: 'date DESC', limit: limit);
    return maps.map((e) => ExpenseTransaction.fromMap(e)).toList();
  }

  Future<List<Category>> getAllCategories() async {
    if (kIsWeb) return List.from(_webCategories);
    final db = await database;
    final maps = await db.query('categories', orderBy: 'id ASC');
    return maps.map((e) => Category.fromMap(e)).toList();
  }

  Future<int> insertChatMessage(ChatMessage msg) async {
    if (kIsWeb) {
      _webChatMessages.add(msg);
      return _webChatMessages.length;
    }
    final db = await database;
    return await db.insert('chat_messages', msg.toMap());
  }

  Future<List<ChatMessage>> getRecentChatMessages({int limit = 50}) async {
    if (kIsWeb) return List.from(_webChatMessages);
    final db = await database;
    final maps = await db.query('chat_messages', orderBy: 'timestamp ASC', limit: limit);
    return maps.map((e) => ChatMessage.fromMap(e)).toList();
  }

  Future<List<Map<String, dynamic>>> getCategorySpendingSummary(DateTime start, DateTime end) async {
    if (kIsWeb) {
      final Map<int, double> catTotals = {};
      for (final tx in _webTransactions) {
        if (tx.isExpense && tx.date.isAfter(start) && tx.date.isBefore(end.add(const Duration(days: 1)))) {
          catTotals[tx.categoryId] = (catTotals[tx.categoryId] ?? 0.0) + tx.amount;
        }
      }
      final List<Map<String, dynamic>> summary = [];
      for (final cat in _webCategories) {
        final spent = catTotals[cat.id] ?? 0.0;
        if (spent > 0) {
          summary.add({
            'category_id': cat.id,
            'category_name': cat.name,
            'budget': cat.monthlyBudget,
            'color': cat.colorValue,
            'total_spent': spent,
          });
        }
      }
      summary.sort((a, b) => (b['total_spent'] as double).compareTo(a['total_spent'] as double));
      return summary;
    }
    final db = await database;
    return await db.rawQuery('''
      SELECT 
        c.id AS category_id,
        c.name AS category_name,
        c.monthly_budget AS budget,
        c.color_value AS color,
        SUM(t.amount) AS total_spent
      FROM transactions t
      JOIN categories c ON t.category_id = c.id
      WHERE t.is_expense = 1 AND t.date >= ? AND t.date <= ?
      GROUP BY c.id
      ORDER BY total_spent DESC
    ''', [start.millisecondsSinceEpoch, end.millisecondsSinceEpoch]);
  }

  Future<ExpenseTransaction?> getHighestExpense() async {
    if (kIsWeb) {
      if (_webTransactions.isEmpty) return null;
      final sorted = List<ExpenseTransaction>.from(_webTransactions)..sort((a, b) => b.amount.compareTo(a.amount));
      return sorted.first;
    }
    final db = await database;
    final maps = await db.query('transactions', where: 'is_expense = 1', orderBy: 'amount DESC', limit: 1);
    if (maps.isNotEmpty) return ExpenseTransaction.fromMap(maps.first);
    return null;
  }
}

// ==========================================
// 3. AI ADVISOR & NATURAL LANGUAGE PARSER
// ==========================================

class AiAdvisorService {
  static Future<Map<String, dynamic>> processUserMessage(String userQuery) async {
    final lower = userQuery.toLowerCase().trim();

    final offTopicKeywords = ['python', 'javascript', 'write code', 'who won', 'joke', 'weather', 'recipe', 'history'];
    for (final word in offTopicKeywords) {
      if (lower.contains(word)) {
        return {
          'text': "I am Penny, your personal offline expense assistant. I am strictly dedicated to your budget, transactions, and money decisions.",
          'loggedExpense': false,
        };
      }
    }

    final logMatch = _tryParseExpense(userQuery);
    if (logMatch != null) {
      final amount = logMatch['amount'] as double;
      final rawTitle = logMatch['title'] as String;

      final categories = await AppDatabase.instance.getAllCategories();
      final category = _detectCategory(rawTitle, categories);

      final newTx = ExpenseTransaction(
        title: rawTitle[0].toUpperCase() + rawTitle.substring(1),
        amount: amount,
        date: DateTime.now(),
        categoryId: category.id!,
        paymentMethod: 'Cash',
      );

      await AppDatabase.instance.insertTransaction(newTx);

      final currency = await AppDatabase.instance.getSetting('currency', '₱');
      final budgetStr = await AppDatabase.instance.getSetting('monthly_budget', '20000.0');
      final totalBudget = double.tryParse(budgetStr) ?? 20000.0;

      final now = DateTime.now();
      final summary = await AppDatabase.instance.getCategorySpendingSummary(DateTime(now.year, now.month, 1), now);
      double totalSpent = 0;
      for (var row in summary) {
        totalSpent += (row['total_spent'] as num).toDouble();
      }
      final remaining = totalBudget - totalSpent;

      return {
        'text': "✅ **Expense Logged!**\n"
            "• Item: **${newTx.title}**\n"
            "• Amount: **$currency${amount.toStringAsFixed(2)}**\n"
            "• Category: **${category.name}**\n\n"
            "💰 Your remaining budget is now **$currency${NumberFormat("#,##0.00").format(remaining)}**.",
        'loggedExpense': true,
      };
    }

    if (lower.contains('daily') || lower.contains('allowance') || lower.contains('per day')) {
      final now = DateTime.now();
      final daysInMonth = DateTime(now.year, now.month + 1, 0).day;
      final daysLeft = (daysInMonth - now.day) + 1;

      final currency = await AppDatabase.instance.getSetting('currency', '₱');
      final budgetStr = await AppDatabase.instance.getSetting('monthly_budget', '20000.0');
      final totalBudget = double.tryParse(budgetStr) ?? 20000.0;

      final summary = await AppDatabase.instance.getCategorySpendingSummary(DateTime(now.year, now.month, 1), now);
      double totalSpent = 0;
      for (var row in summary) {
        totalSpent += (row['total_spent'] as num).toDouble();
      }
      final remaining = totalBudget - totalSpent;
      final dailyAllowance = remaining > 0 ? (remaining / daysLeft) : 0.0;

      return {
        'text': "📅 **Daily Allowance Breakdown:**\n\n"
            "• Days remaining this month: **$daysLeft days**\n"
            "• Total remaining money: **$currency${NumberFormat("#,##0.00").format(remaining)}**\n"
            "• **Safe Daily Limit:** **$currency${NumberFormat("#,##0.00").format(dailyAllowance)} / day**\n\n"
            "${remaining <= 0 ? "⚠️ You have exceeded your monthly budget! Try to pause discretionary spending." : "Stick to this daily amount to comfortably hit your monthly budget!"}",
        'loggedExpense': false,
      };
    }

    if (lower.contains('highest') || lower.contains('biggest')) {
      final currency = await AppDatabase.instance.getSetting('currency', '₱');
      final highest = await AppDatabase.instance.getHighestExpense();
      if (highest == null) {
        return {'text': "You haven't logged any expenses yet this month.", 'loggedExpense': false};
      }
      return {
        'text': "🔍 Your biggest expense so far is **${highest.title}** for **$currency${NumberFormat("#,##0.00").format(highest.amount)}** on ${DateFormat('MMM dd, yyyy').format(highest.date)}.",
        'loggedExpense': false,
      };
    }

    final categories = await AppDatabase.instance.getAllCategories();
    for (var cat in categories) {
      if (lower.contains(cat.name.toLowerCase()) || (cat.name.contains('Food') && lower.contains('food'))) {
        final now = DateTime.now();
        final summary = await AppDatabase.instance.getCategorySpendingSummary(DateTime(now.year, now.month, 1), now);
        final currency = await AppDatabase.instance.getSetting('currency', '₱');
        final match = summary.firstWhere((m) => m['category_id'] == cat.id, orElse: () => <String, dynamic>{});
        final spent = match.isNotEmpty ? (match['total_spent'] as num).toDouble() : 0.0;
        return {
          'text': "📊 For **${cat.name}**, you have spent **$currency${NumberFormat("#,##0.00").format(spent)}** this month.",
          'loggedExpense': false,
        };
      }
    }

    final currency = await AppDatabase.instance.getSetting('currency', '₱');
    final budgetStr = await AppDatabase.instance.getSetting('monthly_budget', '20000.0');
    final totalBudget = double.tryParse(budgetStr) ?? 20000.0;

    final now = DateTime.now();
    final summary = await AppDatabase.instance.getCategorySpendingSummary(DateTime(now.year, now.month, 1), now);
    double totalSpent = 0;
    final categoryLines = <String>[];
    for (var row in summary) {
      final name = row['category_name'];
      final spent = (row['total_spent'] as num).toDouble();
      totalSpent += spent;
      categoryLines.add('• $name: $currency${NumberFormat("#,##0.00").format(spent)}');
    }
    final remaining = totalBudget - totalSpent;

    if (lower.contains('afford')) {
      return {
        'text': "💡 **Affordability Advice:**\n\n"
            "• Monthly Budget: **$currency${NumberFormat("#,##0.00").format(totalBudget)}**\n"
            "• Current Remaining: **$currency${NumberFormat("#,##0.00").format(remaining)}**\n\n"
            "${remaining > 2000 ? "You have room in your budget for essential needs, but make sure non-essential purchases don't consume your remaining buffer!" : "Your remaining budget is tight ($currency${NumberFormat("#,##0.00").format(remaining)}). Consider holding off on any extra purchases!"}",
        'loggedExpense': false,
      };
    }

    return {
      'text': "📋 **Current Financial Snapshot:**\n\n"
          "• Budget: **$currency${NumberFormat("#,##0.00").format(totalBudget)}**\n"
          "• Total Spent: **$currency${NumberFormat("#,##0.00").format(totalSpent)}**\n"
          "• Remaining: **$currency${NumberFormat("#,##0.00").format(remaining)}**\n\n"
          "**Top Categories:**\n"
          "${categoryLines.isEmpty ? "• No expenses logged yet." : categoryLines.join('\n')}\n\n"
          "Tip: You can log an expense right here! Just type: *\"Spent 150 on coffee\"*.",
      'loggedExpense': false,
    };
  }

  static Map<String, dynamic>? _tryParseExpense(String text) {
    final cleaned = text.trim();
    final r1 = RegExp(r'(?:spent|paid|bought|add)\s+(?:[₱\$€£₹])?\s*([0-9]+(?:\.[0-9]+)?)\s+(?:on|for)\s+(.+)', caseSensitive: false);
    final m1 = r1.firstMatch(cleaned);
    if (m1 != null) {
      return {'amount': double.parse(m1.group(1)!), 'title': m1.group(2)!.trim()};
    }

    final r2 = RegExp(r'(.+?)\s+(?:for|cost|was)?\s*(?:[₱\$€£₹])?\s*([0-9]+(?:\.[0-9]+)?)$', caseSensitive: false);
    final m2 = r2.firstMatch(cleaned);
    if (m2 != null) {
      final possibleTitle = m2.group(1)!.trim();
      final nonTitles = ['summary', 'budget', 'afford', 'save', 'money', 'allowance', 'left', 'remaining', 'highest'];
      if (!nonTitles.any((w) => possibleTitle.toLowerCase().contains(w))) {
        return {'amount': double.parse(m2.group(2)!), 'title': possibleTitle};
      }
    }
    return null;
  }

  static Category _detectCategory(String title, List<Category> categories) {
    final t = title.toLowerCase();
    int targetIcon = 0xe532;

    if (t.contains('grocer') || t.contains('market') || t.contains('milk') || t.contains('egg') || t.contains('meat') || t.contains('fruit') || t.contains('veg')) {
      targetIcon = 0xe3ab;
    } else if (t.contains('taxi') || t.contains('bus') || t.contains('fare') || t.contains('gas') || t.contains('fuel') || t.contains('train') || t.contains('grab') || t.contains('angkas') || t.contains('car')) {
      targetIcon = 0xe1d7;
    } else if (t.contains('bill') || t.contains('electric') || t.contains('water') || t.contains('internet') || t.contains('wifi') || t.contains('phone') || t.contains('rent')) {
      targetIcon = 0xe56c;
    } else if (t.contains('movie') || t.contains('game') || t.contains('netflix') || t.contains('concert') || t.contains('party') || t.contains('drink')) {
      targetIcon = 0xe40f;
    } else if (t.contains('med') || t.contains('doctor') || t.contains('drug') || t.contains('clinic') || t.contains('health') || t.contains('hospital')) {
      targetIcon = 0xe3e3;
    }

    return categories.firstWhere(
      (c) => c.iconCodePoint == targetIcon,
      orElse: () => categories.firstWhere((c) => c.isExpense, orElse: () => categories.first),
    );
  }
}

// ==========================================
// 4. MAIN APP SHELL & THEME
// ==========================================

class OfflineExpenseApp extends StatefulWidget {
  const OfflineExpenseApp({super.key});

  static _OfflineExpenseAppState? of(BuildContext context) =>
      context.findAncestorStateOfType<_OfflineExpenseAppState>();

  @override
  State<OfflineExpenseApp> createState() => _OfflineExpenseAppState();
}

class _OfflineExpenseAppState extends State<OfflineExpenseApp> {
  ThemeMode _themeMode = ThemeMode.light;
  String _currency = '₱';

  @override
  void initState() {
    super.initState();
    _loadPreferences();
  }

  Future<void> _loadPreferences() async {
    final darkVal = await AppDatabase.instance.getSetting('dark_mode', '0');
    final curVal = await AppDatabase.instance.getSetting('currency', '₱');
    setState(() {
      _themeMode = darkVal == '1' ? ThemeMode.dark : ThemeMode.light;
      _currency = curVal;
    });
  }

  void toggleTheme() async {
    final newMode = _themeMode == ThemeMode.light ? ThemeMode.dark : ThemeMode.light;
    setState(() => _themeMode = newMode);
    await AppDatabase.instance.setSetting('dark_mode', newMode == ThemeMode.dark ? '1' : '0');
  }

  void updateCurrency(String newCur) async {
    setState(() => _currency = newCur);
    await AppDatabase.instance.setSetting('currency', newCur);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Penny AI Expense Tracker',
      debugShowCheckedModeBanner: false,
      themeMode: _themeMode,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1E88E5), brightness: Brightness.light),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1E88E5), brightness: Brightness.dark),
      ),
      home: MainNavigationShell(currency: _currency),
    );
  }
}

class MainNavigationShell extends StatefulWidget {
  final String currency;
  const MainNavigationShell({super.key, required this.currency});

  @override
  State<MainNavigationShell> createState() => _MainNavigationShellState();
}

class _MainNavigationShellState extends State<MainNavigationShell> {
  int _currentIndex = 0;
  final GlobalKey<_DashboardScreenState> _dashboardKey = GlobalKey();
  final GlobalKey<_TransactionsScreenState> _txKey = GlobalKey();

  void _refreshAll() {
    _dashboardKey.currentState?.loadData();
    _txKey.currentState?.load();
    setState(() {});
  }

  void _openAddTransactionModal([ExpenseTransaction? existing]) async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => AddOrEditTransactionDialog(existing: existing, currency: widget.currency),
    );

    if (result == true) {
      _refreshAll();
    }
  }

  void _showCurrencySelector() {
    final currencies = ['₱', '\$', '€', '£', '₹', '¥', '₩', 'R\$'];
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Select Currency Symbol'),
        content: Wrap(
          spacing: 12,
          runSpacing: 12,
          children: currencies.map((c) {
            return ChoiceChip(
              label: Text(c, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              selected: widget.currency == c,
              onSelected: (selected) {
                if (selected) {
                  OfflineExpenseApp.of(context)?.updateCurrency(c);
                  Navigator.pop(ctx);
                  _refreshAll();
                }
              },
            );
          }).toList(),
        ),
      ),
    );
  }

  void _exportCSV() async {
    final list = await AppDatabase.instance.getAllTransactions();
    final categories = await AppDatabase.instance.getAllCategories();
    final catMap = {for (var c in categories) c.id: c.name};

    final buffer = StringBuffer();
    buffer.writeln('ID,Date,Title,Category,Amount,Payment Method,Note');
    for (var tx in list) {
      final cat = catMap[tx.categoryId] ?? 'General';
      final dt = DateFormat('yyyy-MM-dd HH:mm').format(tx.date);
      buffer.writeln('${tx.id},"$dt","${tx.title}","$cat",${tx.amount},"${tx.paymentMethod}","${tx.note ?? ''}"');
    }

    final csvData = buffer.toString();
    if (!mounted) return;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Exported CSV Data'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Your transaction records in CSV format:'),
              const SizedBox(height: 12),
              Container(
                height: 180,
                padding: const EdgeInsets.all(8),
                color: Theme.of(context).colorScheme.surfaceVariant,
                child: SingleChildScrollView(
                  child: Text(csvData, style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.copy),
            label: const Text('Copy All CSV'),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: csvData));
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('CSV copied to clipboard!')),
              );
            },
          ),
          FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screens = [
      DashboardScreen(key: _dashboardKey, currency: widget.currency, onEdit: _openAddTransactionModal),
      TransactionsScreen(key: _txKey, currency: widget.currency, onEdit: _openAddTransactionModal),
      AiChatScreen(currency: widget.currency, onExpenseLogged: _refreshAll),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            if (_currentIndex == 2) ...[
              const CircleAvatar(radius: 14, backgroundImage: AssetImage('icon.png')),
              const SizedBox(width: 8),
            ],
            Text(_currentIndex == 0 ? 'Monthly Overview' : _currentIndex == 1 ? 'Transactions' : 'Penny (Your AI)'),
          ],
        ),
        actions: [
          IconButton(
            icon: Text(widget.currency, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            tooltip: 'Change Currency',
            onPressed: _showCurrencySelector,
          ),
          IconButton(icon: const Icon(Icons.download), tooltip: 'Export CSV', onPressed: _exportCSV),
          IconButton(
            icon: Icon(Theme.of(context).brightness == Brightness.dark ? Icons.light_mode : Icons.dark_mode),
            tooltip: 'Toggle Dark/Light Mode',
            onPressed: () => OfflineExpenseApp.of(context)?.toggleTheme(),
          ),
        ],
      ),
      body: IndexedStack(index: _currentIndex, children: screens),
      floatingActionButton: _currentIndex != 2
          ? FloatingActionButton.extended(
              onPressed: () => _openAddTransactionModal(),
              icon: const Icon(Icons.add),
              label: const Text('Add Expense'),
            )
          : null,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (idx) => setState(() => _currentIndex = idx),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.dashboard_outlined), selectedIcon: Icon(Icons.dashboard), label: 'Dashboard'),
          NavigationDestination(icon: Icon(Icons.receipt_long_outlined), selectedIcon: Icon(Icons.receipt_long), label: 'Transactions'),
          NavigationDestination(
            icon: CircleAvatar(radius: 12, backgroundImage: AssetImage('icon.png')),
            selectedIcon: CircleAvatar(radius: 12, backgroundImage: AssetImage('icon.png')),
            label: 'Penny AI',
          ),
        ],
      ),
    );
  }
}

// ==========================================
// 5. DASHBOARD SCREEN
// ==========================================

class DashboardScreen extends StatefulWidget {
  final String currency;
  final Function(ExpenseTransaction) onEdit;

  const DashboardScreen({super.key, required this.currency, required this.onEdit});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  double _monthlyBudget = 20000.0;
  double _totalExpenses = 0.0;
  List<Map<String, dynamic>> _summary = [];
  List<ExpenseTransaction> _recent = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    loadData();
  }

  Future<void> loadData() async {
    setState(() => _loading = true);
    final now = DateTime.now();
    final firstDay = DateTime(now.year, now.month, 1);

    final budgetStr = await AppDatabase.instance.getSetting('monthly_budget', '20000.0');
    final summary = await AppDatabase.instance.getCategorySpendingSummary(firstDay, now);
    final recent = await AppDatabase.instance.getAllTransactions(limit: 5);

    double total = 0.0;
    for (var item in summary) {
      total += (item['total_spent'] as num).toDouble();
    }

    if (mounted) {
      setState(() {
        _monthlyBudget = double.tryParse(budgetStr) ?? 20000.0;
        _summary = summary;
        _totalExpenses = total;
        _recent = recent;
        _loading = false;
      });
    }
  }

  void _editBudgetDialog() {
    final controller = TextEditingController(text: _monthlyBudget.toStringAsFixed(0));
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Set Monthly Budget'),
        content: TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            prefixText: '${widget.currency} ',
            labelText: 'Total Monthly Budget',
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final newBudget = double.tryParse(controller.text.trim()) ?? _monthlyBudget;
              await AppDatabase.instance.setSetting('monthly_budget', newBudget.toString());
              if (mounted) {
                Navigator.pop(ctx);
                loadData();
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    final remaining = _monthlyBudget - _totalExpenses;
    final progress = _monthlyBudget > 0 ? (_totalExpenses / _monthlyBudget).clamp(0.0, 1.0) : 0.0;
    final isOverBudget = remaining < 0;

    return RefreshIndicator(
      onRefresh: loadData,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            elevation: 2,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
            color: Theme.of(context).colorScheme.primaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Monthly Budget',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              color: Theme.of(context).colorScheme.onPrimaryContainer,
                            ),
                      ),
                      InkWell(
                        onTap: _editBudgetDialog,
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          child: Row(
                            children: [
                              Text(
                                '${widget.currency}${NumberFormat("#,##0").format(_monthlyBudget)}',
                                style: TextStyle(fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.primary),
                              ),
                              const SizedBox(width: 4),
                              const Icon(Icons.edit, size: 14),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Total Spent', style: TextStyle(fontSize: 12)),
                          Text(
                            '${widget.currency}${NumberFormat("#,##0.00").format(_totalExpenses)}',
                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            isOverBudget ? 'Over Budget' : 'Remaining Money',
                            style: TextStyle(
                              fontSize: 12,
                              color: isOverBudget ? Colors.red : null,
                              fontWeight: isOverBudget ? FontWeight.bold : FontWeight.normal,
                            ),
                          ),
                          Text(
                            '${widget.currency}${NumberFormat("#,##0.00").format(remaining.abs())}',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: isOverBudget ? Colors.red : Colors.green[700],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 10,
                      backgroundColor: Colors.black12,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        isOverBudget ? Colors.red : (progress > 0.85 ? Colors.orange : Colors.green),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      '${(progress * 100).toStringAsFixed(1)}% used',
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          if (_summary.isNotEmpty) ...[
            Text('Spending by Category', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            SizedBox(
              height: 180,
              child: PieChart(
                PieChartData(
                  sectionsSpace: 2,
                  centerSpaceRadius: 40,
                  sections: _summary.map((item) {
                    final spent = (item['total_spent'] as num).toDouble();
                    final colorVal = item['color'] as int;
                    return PieChartSectionData(
                      color: Color(colorVal),
                      value: spent,
                      title: '${widget.currency}${spent.toStringAsFixed(0)}',
                      radius: 50,
                      titleStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white),
                    );
                  }).toList(),
                ),
              ),
            ),
            const SizedBox(height: 20),
          ],
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Recent Expenses', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
              const Text('Swipe to delete • Tap to edit', style: TextStyle(fontSize: 11, color: Colors.grey)),
            ],
          ),
          const SizedBox(height: 8),
          if (_recent.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 30),
              child: Center(child: Text('No expenses recorded yet. Tap + to add!')),
            )
          else
            ..._recent.map((tx) => Dismissible(
                  key: Key('recent_${tx.id}'),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 20),
                    color: Colors.red,
                    child: const Icon(Icons.delete, color: Colors.white),
                  ),
                  onDismissed: (_) async {
                    await AppDatabase.instance.deleteTransaction(tx.id!);
                    loadData();
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Deleted "${tx.title}"')));
                  },
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    onTap: () => widget.onEdit(tx),
                    leading: CircleAvatar(
                      backgroundColor: Theme.of(context).colorScheme.surfaceVariant,
                      child: const Icon(Icons.receipt),
                    ),
                    title: Text(tx.title),
                    subtitle: Text(DateFormat('MMM dd, yyyy').format(tx.date)),
                    trailing: Text(
                      '-${widget.currency}${NumberFormat("#,##0.00").format(tx.amount)}',
                      style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.redAccent),
                    ),
                  ),
                )),
          const SizedBox(height: 60),
        ],
      ),
    );
  }
}

// ==========================================
// 6. TRANSACTIONS SCREEN
// ==========================================

class TransactionsScreen extends StatefulWidget {
  final String currency;
  final Function(ExpenseTransaction) onEdit;

  const TransactionsScreen({super.key, required this.currency, required this.onEdit});

  @override
  State<TransactionsScreen> createState() => _TransactionsScreenState();
}

class _TransactionsScreenState extends State<TransactionsScreen> {
  List<ExpenseTransaction> _transactions = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() => _loading = true);
    final list = await AppDatabase.instance.getAllTransactions(limit: 200);
    if (mounted) setState(() { _transactions = list; _loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    return _transactions.isEmpty
        ? const Center(child: Text('No transactions yet.'))
        : ListView.separated(
            itemCount: _transactions.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final tx = _transactions[i];
              return Dismissible(
                key: Key('all_tx_${tx.id}'),
                direction: DismissDirection.endToStart,
                background: Container(
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 20),
                  color: Colors.red,
                  child: const Icon(Icons.delete, color: Colors.white),
                ),
                onDismissed: (_) async {
                  await AppDatabase.instance.deleteTransaction(tx.id!);
                  load();
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Deleted "${tx.title}"')));
                },
                child: ListTile(
                  onTap: () => widget.onEdit(tx),
                  title: Text(tx.title),
                  subtitle: Text('${DateFormat('MMM dd, yyyy').format(tx.date)} • ${tx.paymentMethod}'),
                  trailing: Text(
                    '-${widget.currency}${NumberFormat("#,##0.00").format(tx.amount)}',
                    style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold),
                  ),
                ),
              );
            },
          );
  }
}

// ==========================================
// 7. AI CHAT SCREEN (PENNY)
// ==========================================

class AiChatScreen extends StatefulWidget {
  final String currency;
  final VoidCallback onExpenseLogged;

  const AiChatScreen({super.key, required this.currency, required this.onExpenseLogged});

  @override
  State<AiChatScreen> createState() => _AiChatScreenState();
}

class _AiChatScreenState extends State<AiChatScreen> {
  final TextEditingController _controller = TextEditingController();
  final List<ChatMessage> _messages = [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadChat();
  }

  Future<void> _loadChat() async {
    final history = await AppDatabase.instance.getRecentChatMessages();
    setState(() {
      _messages.addAll(history);
      if (_messages.isEmpty) {
        _messages.add(
          ChatMessage(
            sender: ChatSender.assistant,
            content: "Hello! I'm Penny, your offline AI advisor.\n\n"
                "• Ask me about your **budget, daily allowance, or spending**\n"
                "• Or log an expense by typing: *\"Spent 150 on coffee\"*!",
            timestamp: DateTime.now(),
          ),
        );
      }
    });
  }

  Future<void> _send(String text) async {
    final query = text.trim();
    if (query.isEmpty || _busy) return;
    _controller.clear();

    final userMsg = ChatMessage(sender: ChatSender.user, content: query, timestamp: DateTime.now());
    setState(() { _messages.add(userMsg); _busy = true; });
    await AppDatabase.instance.insertChatMessage(userMsg);

    final result = await AiAdvisorService.processUserMessage(query);
    final reply = result['text'] as String;
    final didLog = result['loggedExpense'] as bool;

    final aiMsg = ChatMessage(sender: ChatSender.assistant, content: reply, timestamp: DateTime.now());
    await AppDatabase.instance.insertChatMessage(aiMsg);

    if (mounted) {
      setState(() { _messages.add(aiMsg); _busy = false; });
      if (didLog) {
        widget.onExpenseLogged();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              ActionChip(
                avatar: const Icon(Icons.today, size: 16),
                label: const Text('Daily Allowance?'),
                onPressed: () => _send('What is my safe daily allowance for the rest of the month?'),
              ),
              const SizedBox(width: 8),
              ActionChip(
                avatar: const Icon(Icons.star, size: 16),
                label: const Text('Biggest Expense?'),
                onPressed: () => _send('What was my highest expense so far?'),
              ),
              const SizedBox(width: 8),
              ActionChip(
                avatar: const Icon(Icons.account_balance_wallet, size: 16),
                label: const Text('Remaining Budget?'),
                onPressed: () => _send('How much money do I have remaining in my budget this month?'),
              ),
              const SizedBox(width: 8),
              ActionChip(
                avatar: const Icon(Icons.restaurant, size: 16),
                label: const Text('Food Spending?'),
                onPressed: () => _send('How much have I spent on food this month?'),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: _messages.length,
            itemBuilder: (context, i) {
              final m = _messages[i];
              final isUser = m.sender == ChatSender.user;
              return Align(
                alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (!isUser) ...[
                      const CircleAvatar(radius: 14, backgroundImage: AssetImage('icon.png')),
                      const SizedBox(width: 8),
                    ],
                    Flexible(
                      child: Container(
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
                        decoration: BoxDecoration(
                          color: isUser ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.surfaceVariant,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Text(
                          m.content,
                          style: TextStyle(
                            color: isUser ? Theme.of(context).colorScheme.onPrimary : Theme.of(context).colorScheme.onSurfaceVariant,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        if (_busy)
          const Padding(
            padding: EdgeInsets.all(8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CircleAvatar(radius: 8, backgroundImage: AssetImage('icon.png')),
                SizedBox(width: 8),
                Text('Penny is thinking...', style: TextStyle(fontSize: 12)),
              ],
            ),
          ),
        SafeArea(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: const InputDecoration(
                      hintText: 'e.g. "Spent 250 on pizza" or ask a question...',
                      border: InputBorder.none,
                    ),
                    onSubmitted: _send,
                  ),
                ),
                IconButton(icon: const Icon(Icons.send), onPressed: () => _send(_controller.text)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ==========================================
// 8. ADD OR EDIT TRANSACTION MODAL
// ==========================================

class AddOrEditTransactionDialog extends StatefulWidget {
  final ExpenseTransaction? existing;
  final String currency;

  const AddOrEditTransactionDialog({super.key, this.existing, required this.currency});

  @override
  State<AddOrEditTransactionDialog> createState() => _AddOrEditTransactionDialogState();
}

class _AddOrEditTransactionDialogState extends State<AddOrEditTransactionDialog> {
  late final TextEditingController _titleController;
  late final TextEditingController _amountController;
  late DateTime _selectedDate;
  List<Category> _categories = [];
  Category? _selectedCategory;
  String _paymentMethod = 'Cash';

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.existing?.title ?? '');
    _amountController = TextEditingController(text: widget.existing != null ? widget.existing!.amount.toString() : '');
    _selectedDate = widget.existing?.date ?? DateTime.now();
    _paymentMethod = widget.existing?.paymentMethod ?? 'Cash';
    _fetchCategories();
  }

  Future<void> _fetchCategories() async {
    final list = await AppDatabase.instance.getAllCategories();
    setState(() {
      _categories = list.where((c) => c.isExpense).toList();
      if (_categories.isNotEmpty) {
        if (widget.existing != null) {
          _selectedCategory = _categories.firstWhere(
            (c) => c.id == widget.existing!.categoryId,
            orElse: () => _categories.first,
          );
        } else {
          _selectedCategory = _categories.first;
        }
      }
    });
  }

  void _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
    );
    if (picked != null) {
      setState(() => _selectedDate = picked);
    }
  }

  Future<void> _save() async {
    final title = _titleController.text.trim();
    final amount = double.tryParse(_amountController.text.trim()) ?? 0.0;

    if (title.isEmpty || amount <= 0 || _selectedCategory == null) return;

    if (widget.existing == null) {
      final tx = ExpenseTransaction(
        title: title,
        amount: amount,
        date: _selectedDate,
        categoryId: _selectedCategory!.id!,
        paymentMethod: _paymentMethod,
      );
      await AppDatabase.instance.insertTransaction(tx);
    } else {
      final updated = ExpenseTransaction(
        id: widget.existing!.id,
        title: title,
        amount: amount,
        date: _selectedDate,
        categoryId: _selectedCategory!.id!,
        paymentMethod: _paymentMethod,
      );
      await AppDatabase.instance.updateTransaction(updated);
    }

    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.existing != null;

    return Container(
      padding: EdgeInsets.only(left: 20, right: 20, top: 24, bottom: MediaQuery.of(context).viewInsets.bottom + 24),
      decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface, borderRadius: const BorderRadius.vertical(top: Radius.circular(24))),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              isEditing ? 'Edit Expense' : 'Add New Expense',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 14),
            TextField(controller: _titleController, decoration: const InputDecoration(labelText: 'Expense Name', border: OutlineInputBorder())),
            const SizedBox(height: 12),
            TextField(
              controller: _amountController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                prefixText: '${widget.currency} ',
                labelText: 'Amount',
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            if (_categories.isNotEmpty)
              DropdownButtonFormField<Category>(
                value: _selectedCategory,
                decoration: const InputDecoration(labelText: 'Category', border: OutlineInputBorder()),
                items: _categories.map((c) => DropdownMenuItem(value: c, child: Text(c.name))).toList(),
                onChanged: (v) => setState(() => _selectedCategory = v),
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _paymentMethod,
                    decoration: const InputDecoration(labelText: 'Payment Method', border: OutlineInputBorder()),
                    items: const [
                      DropdownMenuItem(value: 'Cash', child: Text('Cash')),
                      DropdownMenuItem(value: 'Debit Card', child: Text('Debit Card')),
                      DropdownMenuItem(value: 'Credit Card', child: Text('Credit Card')),
                      DropdownMenuItem(value: 'E-Wallet', child: Text('E-Wallet')),
                    ],
                    onChanged: (v) => setState(() => _paymentMethod = v ?? 'Cash'),
                  ),
                ),
                const SizedBox(width: 10),
                OutlinedButton.icon(
                  onPressed: _pickDate,
                  icon: const Icon(Icons.calendar_today, size: 16),
                  label: Text(DateFormat('MM/dd').format(_selectedDate)),
                ),
              ],
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.check),
              label: Text(isEditing ? 'Update Expense' : 'Save Expense'),
            ),
          ],
        ),
      ),
    );
  }
}
