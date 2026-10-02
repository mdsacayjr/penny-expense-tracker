import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Load storage + saved theme/currency BEFORE the first frame (no light-mode flash).
  await AppDatabase.instance.init();
  final dark = await AppDatabase.instance.getSetting('dark_mode', '0');
  final cur = await AppDatabase.instance.getSetting('currency', '₱');
  runApp(OfflineExpenseApp(initialDark: dark == '1', initialCurrency: cur));
}

// ==========================================
// 0. SMALL HELPERS
// ==========================================

String _money(double v) => NumberFormat('#,##0.00').format(v);

/// Parsed data from a split-expense note prefix like `[split:2:200.00]extra note`.
class _SplitInfo {
  final int count;
  final double originalAmount;
  final String? userNote;
  const _SplitInfo({required this.count, required this.originalAmount, this.userNote});
}

/// Returns [_SplitInfo] when a split prefix is present in [note], otherwise null.
_SplitInfo? _parseSplitNote(String? note) {
  if (note == null) return null;
  final match = RegExp(r'^\[split:(\d+):([\d.]+)\](.*)$', dotAll: true).firstMatch(note);
  if (match == null) return null;
  final count = int.tryParse(match.group(1)!) ?? 0;
  final original = double.tryParse(match.group(2)!) ?? 0.0;
  final rest = match.group(3)!.trim();
  return _SplitInfo(count: count, originalAmount: original, userNote: rest.isEmpty ? null : rest);
}

/// Half-open range [start of month, start of next month).
DateTimeRange monthRange(DateTime ref) => DateTimeRange(
      start: DateTime(ref.year, ref.month, 1),
      end: DateTime(ref.year, ref.month + 1, 1),
    );

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
// 2. UNIVERSAL STORAGE
//    SQLite on mobile, SharedPreferences-backed store on web
// ==========================================

class AppDatabase {
  static final AppDatabase instance = AppDatabase._init();
  Future<Database>? _dbFuture; // cached so concurrent callers never open twice

  // ---- Web fallback (persisted in SharedPreferences) ----
  static SharedPreferences? _prefs;
  static int _webNextTxId = 1;

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

  /// Call once from main(): opens SQLite on mobile, loads saved data on web.
  Future<void> init() async {
    if (kIsWeb) {
      _prefs = await SharedPreferences.getInstance();
      _loadWebState();
    } else {
      await database;
    }
  }

  void _loadWebState() {
    final prefs = _prefs;
    if (prefs == null) return;
    try {
      final s = prefs.getString('web_settings');
      if (s != null) {
        _webSettings.addAll(Map<String, String>.from(jsonDecode(s) as Map));
      }
      final t = prefs.getString('web_transactions');
      if (t != null) {
        _webTransactions
          ..clear()
          ..addAll((jsonDecode(t) as List).map((e) => ExpenseTransaction.fromMap(Map<String, dynamic>.from(e as Map))));
      }
      final c = prefs.getString('web_chat');
      if (c != null) {
        _webChatMessages
          ..clear()
          ..addAll((jsonDecode(c) as List).map((e) => ChatMessage.fromMap(Map<String, dynamic>.from(e as Map))));
      }
    } catch (e) {
      debugPrint('Failed to load web state: $e');
    }
    var maxId = 0;
    for (final tx in _webTransactions) {
      if ((tx.id ?? 0) > maxId) maxId = tx.id!;
    }
    _webNextTxId = maxId + 1;
  }

  Future<void> _saveWeb() async {
    final prefs = _prefs;
    if (prefs == null) return;
    if (_webChatMessages.length > 200) {
      _webChatMessages.removeRange(0, _webChatMessages.length - 200);
    }
    await prefs.setString('web_settings', jsonEncode(_webSettings));
    await prefs.setString('web_transactions', jsonEncode(_webTransactions.map((e) => e.toMap()).toList()));
    await prefs.setString('web_chat', jsonEncode(_webChatMessages.map((e) => e.toMap()).toList()));
  }

  // ---- SQLite ----
  Future<Database> get database => _dbFuture ??= _initDB('expense_tracker_v3.db').catchError((e) {
    _dbFuture = null; // clear so the next call can retry
    throw e;
  });

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final fullPath = p.join(dbPath, filePath);
    return await openDatabase(
      fullPath,
      version: 2,
      onConfigure: (db) async => await db.execute('PRAGMA foreign_keys = ON'),
      onCreate: _createDB,
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('CREATE INDEX IF NOT EXISTS idx_tx_category ON transactions(category_id)');
        }
      },
    );
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
    await db.execute('CREATE INDEX idx_tx_category ON transactions(category_id)');

    await db.insert('settings', {'key': 'monthly_budget', 'value': '20000.0'});
    await db.insert('settings', {'key': 'currency', 'value': '₱'});
    await db.insert('settings', {'key': 'dark_mode', 'value': '0'});

    for (final cat in _webCategories) {
      await db.insert('categories', cat.toMap());
    }
  }

  // ---- Settings ----
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
      await _saveWeb();
      return;
    }
    final db = await database;
    await db.insert('settings', {'key': key, 'value': value}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // ---- Transactions ----
  /// If [tx.id] is set (e.g. re-inserting after "Undo"), that id is kept.
  Future<int> insertTransaction(ExpenseTransaction tx) async {
    if (kIsWeb) {
      final id = tx.id ?? _webNextTxId;
      if (id >= _webNextTxId) _webNextTxId = id + 1;
      final newTx = ExpenseTransaction(
        id: id,
        title: tx.title,
        amount: tx.amount,
        date: tx.date,
        categoryId: tx.categoryId,
        isExpense: tx.isExpense,
        paymentMethod: tx.paymentMethod,
        note: tx.note,
      );
      _webTransactions.insert(0, newTx);
      await _saveWeb();
      return id;
    }
    final db = await database;
    return await db.insert('transactions', tx.toMap());
  }

  Future<int> updateTransaction(ExpenseTransaction tx) async {
    if (kIsWeb) {
      final index = _webTransactions.indexWhere((t) => t.id == tx.id);
      if (index != -1) _webTransactions[index] = tx;
      await _saveWeb();
      return 1;
    }
    final db = await database;
    return await db.update('transactions', tx.toMap(), where: 'id = ?', whereArgs: [tx.id]);
  }

  Future<int> deleteTransaction(int id) async {
    if (kIsWeb) {
      _webTransactions.removeWhere((t) => t.id == id);
      await _saveWeb();
      return 1;
    }
    final db = await database;
    return await db.delete('transactions', where: 'id = ?', whereArgs: [id]);
  }

  Future<List<ExpenseTransaction>> getAllTransactions({int limit = 200}) async {
    if (kIsWeb) {
      final sorted = List<ExpenseTransaction>.from(_webTransactions)..sort((a, b) => b.date.compareTo(a.date));
      return sorted.take(limit).toList();
    }
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

  // ---- Chat ----
  Future<int> insertChatMessage(ChatMessage msg) async {
    if (kIsWeb) {
      _webChatMessages.add(msg);
      await _saveWeb();
      return _webChatMessages.length;
    }
    final db = await database;
    return await db.insert('chat_messages', msg.toMap());
  }

  /// Returns the most RECENT [limit] messages, oldest-first.
  Future<List<ChatMessage>> getRecentChatMessages({int limit = 50}) async {
    if (kIsWeb) {
      final all = List<ChatMessage>.from(_webChatMessages);
      return all.length > limit ? all.sublist(all.length - limit) : all;
    }
    final db = await database;
    final maps = await db.query('chat_messages', orderBy: 'timestamp DESC', limit: limit);
    return maps.map((e) => ChatMessage.fromMap(e)).toList().reversed.toList();
  }

  // ---- Reports (range is half-open: start <= date < end) ----
  Future<List<Map<String, dynamic>>> getCategorySpendingSummary(DateTimeRange range) async {
    if (kIsWeb) {
      final Map<int, double> catTotals = {};
      for (final tx in _webTransactions) {
        if (tx.isExpense && !tx.date.isBefore(range.start) && tx.date.isBefore(range.end)) {
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
      WHERE t.is_expense = 1 AND t.date >= ? AND t.date < ?
      GROUP BY c.id
      ORDER BY total_spent DESC
    ''', [range.start.millisecondsSinceEpoch, range.end.millisecondsSinceEpoch]);
  }

  Future<ExpenseTransaction?> getHighestExpense(DateTimeRange range) async {
    if (kIsWeb) {
      final inRange = _webTransactions
          .where((t) => t.isExpense && !t.date.isBefore(range.start) && t.date.isBefore(range.end))
          .toList()
        ..sort((a, b) => b.amount.compareTo(a.amount));
      return inRange.isEmpty ? null : inRange.first;
    }
    final db = await database;
    final maps = await db.query(
      'transactions',
      where: 'is_expense = 1 AND date >= ? AND date < ?',
      whereArgs: [range.start.millisecondsSinceEpoch, range.end.millisecondsSinceEpoch],
      orderBy: 'amount DESC',
      limit: 1,
    );
    if (maps.isNotEmpty) return ExpenseTransaction.fromMap(maps.first);
    return null;
  }
}

// ==========================================
// 3. AI ADVISOR & NATURAL LANGUAGE PARSER
// ==========================================

/// An expense Penny is not sure about — the user must confirm it first.
class PendingExpense {
  final String title;
  final double amount;
  const PendingExpense(this.title, this.amount);
}

class AdvisorReply {
  final String text;
  final int? loggedTxId; // set when an expense was actually saved (enables Undo)
  final PendingExpense? pending; // set when Penny asks "log this?"
  const AdvisorReply(this.text, {this.loggedTxId, this.pending});
}

class _ParsedExpense {
  final String title;
  final double amount;
  final bool confident; // true only when a clear verb like "spent/paid/bought/add" was used
  const _ParsedExpense(this.title, this.amount, this.confident);
}

class _MonthStats {
  final String currency;
  final double budget;
  final double spent;
  final List<Map<String, dynamic>> summary;
  const _MonthStats(this.currency, this.budget, this.spent, this.summary);
  double get remaining => budget - spent;
}

class AiAdvisorService {
  static final RegExp _offTopic = RegExp(r'\b(?:python|javascript|write code|who won|jokes?|weather|recipes?)\b');
  static final RegExp _questionStart = RegExp(r'^(?:what|how|when|where|why|who|which|show|can|could|do|does|did|is|are|am)\b');
  static final RegExp _nonTitles = RegExp(r'\b(?:summary|budget|afford|save|money|allowance|left|remaining|highest|biggest)\b');

  static Future<_MonthStats> _stats() async {
    final currency = await AppDatabase.instance.getSetting('currency', '₱');
    final budgetStr = await AppDatabase.instance.getSetting('monthly_budget', '20000.0');
    final budget = double.tryParse(budgetStr) ?? 20000.0;
    final summary = await AppDatabase.instance.getCategorySpendingSummary(monthRange(DateTime.now()));
    double spent = 0;
    for (final row in summary) {
      spent += (row['total_spent'] as num).toDouble();
    }
    return _MonthStats(currency, budget, spent, summary);
  }

  /// Saves the expense and returns a reply that carries the new id (for Undo).
  static Future<AdvisorReply> logExpense(String rawTitle, double amount) async {
    final categories = await AppDatabase.instance.getAllCategories();
    final category = _detectCategory(rawTitle, categories);
    final title = rawTitle[0].toUpperCase() + rawTitle.substring(1);

    final id = await AppDatabase.instance.insertTransaction(ExpenseTransaction(
      title: title,
      amount: amount,
      date: DateTime.now(),
      categoryId: category.id!,
      paymentMethod: 'Cash',
    ));

    final s = await _stats();
    return AdvisorReply(
      "✅ **Expense Logged!**\n"
      "• Item: **$title**\n"
      "• Amount: **${s.currency}${amount.toStringAsFixed(2)}**\n"
      "• Category: **${category.name}**\n\n"
      "💰 Your remaining budget is now **${s.currency}${_money(s.remaining)}**.",
      loggedTxId: id,
    );
  }

  static Future<AdvisorReply> processUserMessage(String userQuery) async {
    final lower = userQuery.toLowerCase().trim();

    if (_offTopic.hasMatch(lower)) {
      return const AdvisorReply(
          "I am Penny, your personal offline expense assistant. I am strictly dedicated to your budget, transactions, and money decisions.");
    }

    final parsed = _tryParseExpense(userQuery);
    if (parsed != null) {
      if (parsed.confident) {
        return logExpense(parsed.title, parsed.amount);
      }
      final currency = await AppDatabase.instance.getSetting('currency', '₱');
      return AdvisorReply(
        "🤔 Did you want me to log **${parsed.title}** for **$currency${_money(parsed.amount)}**?",
        pending: PendingExpense(parsed.title, parsed.amount),
      );
    }

    if (lower.contains('daily') || lower.contains('allowance') || lower.contains('per day')) {
      final now = DateTime.now();
      final daysInMonth = DateTime(now.year, now.month + 1, 0).day;
      final daysLeft = (daysInMonth - now.day) + 1;
      final s = await _stats();
      final dailyAllowance = s.remaining > 0 ? (s.remaining / daysLeft) : 0.0;

      return AdvisorReply(
        "📅 **Daily Allowance Breakdown:**\n\n"
        "• Days remaining this month: **$daysLeft days**\n"
        "• Total remaining money: **${s.currency}${_money(s.remaining)}**\n"
        "• **Safe Daily Limit:** **${s.currency}${_money(dailyAllowance)} / day**\n\n"
        "${s.remaining <= 0 ? "⚠️ You have exceeded your monthly budget! Try to pause discretionary spending." : "Stick to this daily amount to comfortably hit your monthly budget!"}",
      );
    }

    if (lower.contains('highest') || lower.contains('biggest')) {
      final currency = await AppDatabase.instance.getSetting('currency', '₱');
      final highest = await AppDatabase.instance.getHighestExpense(monthRange(DateTime.now()));
      if (highest == null) {
        return const AdvisorReply("You haven't logged any expenses yet this month.");
      }
      return AdvisorReply(
        "🔍 Your biggest expense this month is **${highest.title}** for **$currency${_money(highest.amount)}** on ${DateFormat('MMM dd, yyyy').format(highest.date)}.",
      );
    }

    final categories = await AppDatabase.instance.getAllCategories();
    final words = lower.split(RegExp(r'[^a-z]+')).where((w) => w.length >= 4).toList();
    for (final cat in categories.where((c) => c.isExpense)) {
      final tokens = cat.name.toLowerCase().split(RegExp(r'[^a-z]+')).where((t) => t.length >= 4).toList();
      final hit = words.any((w) => tokens.any((t) => t.startsWith(w) || w.startsWith(t)));
      if (hit) {
        final s = await _stats();
        final match = s.summary.firstWhere((m) => m['category_id'] == cat.id, orElse: () => <String, dynamic>{});
        final spent = match.isNotEmpty ? (match['total_spent'] as num).toDouble() : 0.0;
        return AdvisorReply("📊 For **${cat.name}**, you have spent **${s.currency}${_money(spent)}** this month.");
      }
    }

    final s = await _stats();

    if (lower.contains('afford')) {
      return AdvisorReply(
        "💡 **Affordability Advice:**\n\n"
        "• Monthly Budget: **${s.currency}${_money(s.budget)}**\n"
        "• Current Remaining: **${s.currency}${_money(s.remaining)}**\n\n"
        "${s.remaining > 2000 ? "You have room in your budget for essential needs, but make sure non-essential purchases don't consume your remaining buffer!" : "Your remaining budget is tight (${s.currency}${_money(s.remaining)}). Consider holding off on any extra purchases!"}",
      );
    }

    final categoryLines = s.summary
        .map((row) => '• ${row['category_name']}: ${s.currency}${_money((row['total_spent'] as num).toDouble())}')
        .toList();

    return AdvisorReply(
      "📋 **Current Financial Snapshot:**\n\n"
      "• Budget: **${s.currency}${_money(s.budget)}**\n"
      "• Total Spent: **${s.currency}${_money(s.spent)}**\n"
      "• Remaining: **${s.currency}${_money(s.remaining)}**\n\n"
      "**Top Categories:**\n"
      "${categoryLines.isEmpty ? "• No expenses logged yet." : categoryLines.join('\n')}\n\n"
      "Tip: You can log an expense right here! Just type: *\"Spent 150 on coffee\"*.",
    );
  }

  static const String _amt = r'([0-9][0-9,]*(?:\.[0-9]+)?)\s*(k\b)?';

  static double? _toAmount(String raw, String? kSuffix) {
    final v = double.tryParse(raw.replaceAll(',', ''));
    if (v == null) return null;
    return kSuffix != null ? v * 1000 : v;
  }

  static _ParsedExpense? _tryParseExpense(String text) {
    final cleaned = text.trim();
    final lower = cleaned.toLowerCase();

    final r1 = RegExp(
      r'(?:spent|paid|bought|add)\s+(?:[₱\$€£₹])?\s*' + _amt + r'\s+(?:on|for)\s+(.+)',
      caseSensitive: false,
    );
    final m1 = r1.firstMatch(cleaned);
    if (m1 != null && !cleaned.contains('?')) {
      final amount = _toAmount(m1.group(1)!, m1.group(2));
      final title = m1.group(3)!.trim();
      if (amount != null && amount > 0 && title.isNotEmpty) {
        return _ParsedExpense(title, amount, true);
      }
    }

    if (cleaned.contains('?') || _questionStart.hasMatch(lower)) return null;
    final r2 = RegExp(
      r'^(.+?)\s+(?:(?:for|cost|was)\s+)?(?:[₱\$€£₹])?\s*' + _amt + r'$',
      caseSensitive: false,
    );
    final m2 = r2.firstMatch(cleaned);
    if (m2 != null) {
      final possibleTitle = m2.group(1)!.trim();
      final amount = _toAmount(m2.group(2)!, m2.group(3));
      if (amount != null && amount > 0 && possibleTitle.isNotEmpty && !_nonTitles.hasMatch(possibleTitle.toLowerCase())) {
        return _ParsedExpense(possibleTitle, amount, false);
      }
    }
    return null;
  }

  static final Map<String, RegExp> _categoryRules = {
    'Groceries': RegExp(r'\b(?:grocer(?:y|ies)|market|milk|eggs?|meat|fruits?|veg(?:gies|etables?)?|rice)\b'),
    'Transportation': RegExp(r'\b(?:taxi|bus|fare|gas|fuel|train|grab|angkas|car|jeep(?:ney)?|toll|parking|mrt|lrt)\b'),
    'Utilities & Bills': RegExp(r'\b(?:bills?|electric(?:ity)?|water|internet|wifi|phone|rent)\b'),
    'Entertainment': RegExp(r'\b(?:movies?|games?|netflix|spotify|concert|party)\b'),
    'Health & Care': RegExp(r'\b(?:meds?|medicine|doctor|drugs?|clinic|health|hospital|pharmacy|vitamins?)\b'),
  };

  static Category _detectCategory(String title, List<Category> categories) {
    final t = title.toLowerCase();
    String? target;
    for (final e in _categoryRules.entries) {
      if (e.value.hasMatch(t)) {
        target = e.key;
        break;
      }
    }
    final expenseCats = categories.where((c) => c.isExpense).toList();
    if (target != null) {
      for (final c in expenseCats) {
        if (c.name == target) return c;
      }
    }
    return expenseCats.isNotEmpty ? expenseCats.first : categories.first;
  }
}

// ==========================================
// 4. MAIN APP SHELL & THEME
// ==========================================

class OfflineExpenseApp extends StatefulWidget {
  final bool initialDark;
  final String initialCurrency;
  const OfflineExpenseApp({super.key, this.initialDark = false, this.initialCurrency = '₱'});

  static _OfflineExpenseAppState? of(BuildContext context) =>
      context.findAncestorStateOfType<_OfflineExpenseAppState>();

  @override
  State<OfflineExpenseApp> createState() => _OfflineExpenseAppState();
}

class _OfflineExpenseAppState extends State<OfflineExpenseApp> {
  late ThemeMode _themeMode;
  late String _currency;

  @override
  void initState() {
    super.initState();
    _themeMode = widget.initialDark ? ThemeMode.dark : ThemeMode.light;
    _currency = widget.initialCurrency;
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
    if (mounted) setState(() {});
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

  String _csv(String s) => s.replaceAll('"', '""');

  void _exportCSV() async {
    final list = await AppDatabase.instance.getAllTransactions();
    final categories = await AppDatabase.instance.getAllCategories();
    final catMap = {for (var c in categories) c.id: c.name};

    final buffer = StringBuffer();
    buffer.writeln('ID,Date,Title,Category,Amount,Payment Method,Note');
    for (var tx in list) {
      final cat = catMap[tx.categoryId] ?? 'General';
      final dt = DateFormat('yyyy-MM-dd HH:mm').format(tx.date);
      buffer.writeln('${tx.id},"$dt","${_csv(tx.title)}","${_csv(cat)}",${tx.amount},"${_csv(tx.paymentMethod)}","${_csv(tx.note ?? '')}"');
    }

    final csvData = buffer.toString();
    if (!context.mounted) return;

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
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
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
      DashboardScreen(key: _dashboardKey, currency: widget.currency, onEdit: _openAddTransactionModal, onChanged: _refreshAll),
      TransactionsScreen(key: _txKey, currency: widget.currency, onEdit: _openAddTransactionModal, onChanged: _refreshAll),
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
      floatingActionButton: _currentIndex == 0
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
  final VoidCallback onChanged;

  const DashboardScreen({super.key, required this.currency, required this.onEdit, required this.onChanged});

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
    final range = monthRange(DateTime.now());

    final budgetStr = await AppDatabase.instance.getSetting('monthly_budget', '20000.0');
    final summary = await AppDatabase.instance.getCategorySpendingSummary(range);
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
              final newBudget = double.tryParse(controller.text.trim().replaceAll(',', '')) ?? _monthlyBudget;
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

  Future<void> _deleteWithUndo(ExpenseTransaction tx) async {
    setState(() => _recent.removeWhere((t) => t.id == tx.id));
    await AppDatabase.instance.deleteTransaction(tx.id!);
    widget.onChanged();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('Deleted "${tx.title}"'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () async {
            await AppDatabase.instance.insertTransaction(tx);
            widget.onChanged();
          },
        ),
      ));
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
                            '${widget.currency}${_money(_totalExpenses)}',
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
                            '${widget.currency}${_money(remaining.abs())}',
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
            const SizedBox(height: 14),
            // --- Legend ---
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: _summary.map((item) {
                final colorVal = item['color'] as int;
                final name = item['category_name'] as String;
                final spent = (item['total_spent'] as num).toDouble();
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: Color(colorVal),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      name,
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '${widget.currency}${_money(spent)}',
                      style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.outline),
                    ),
                  ],
                );
              }).toList(),
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
                  onDismissed: (_) => _deleteWithUndo(tx),
                  child: Builder(builder: (context) {
                    final split = _parseSplitNote(tx.note);
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      onTap: () => widget.onEdit(tx),
                      leading: CircleAvatar(
                        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                        child: const Icon(Icons.receipt),
                      ),
                      title: Text(tx.title),
                      subtitle: split != null
                          ? Row(children: [
                              Text(DateFormat('MMM dd, yyyy').format(tx.date)),
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                decoration: BoxDecoration(
                                  color: Theme.of(context).colorScheme.secondaryContainer,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text('÷${split.count}', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                              ),
                            ])
                          : Text(DateFormat('MMM dd, yyyy').format(tx.date)),
                      trailing: split != null
                          ? Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  '-${widget.currency}${_money(tx.amount)}',
                                  style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.redAccent, fontSize: 14),
                                ),
                                Text(
                                  'of ${widget.currency}${_money(split.originalAmount)}',
                                  style: TextStyle(fontSize: 10, color: Theme.of(context).colorScheme.outline),
                                ),
                              ],
                            )
                          : Text(
                              '${tx.isExpense ? '-' : '+'}${widget.currency}${_money(tx.amount)}',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: tx.isExpense ? Colors.redAccent : Colors.green[700],
                              ),
                            ),
                    );
                  }),
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
  final VoidCallback onChanged;

  const TransactionsScreen({super.key, required this.currency, required this.onEdit, required this.onChanged});

  @override
  State<TransactionsScreen> createState() => _TransactionsScreenState();
}

class _TransactionsScreenState extends State<TransactionsScreen> {
  List<ExpenseTransaction> _transactions = [];
  bool _loading = true;

  // --- Multi-select state ---
  final Set<int> _selectedIds = {};
  bool get _isSelecting => _selectedIds.isNotEmpty;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final list = await AppDatabase.instance.getAllTransactions(limit: 200);
    if (mounted) {
      setState(() {
        _transactions = list;
        _loading = false;
      });
    }
  }

  Future<void> _deleteWithUndo(ExpenseTransaction tx) async {
    setState(() {
      _transactions.removeWhere((t) => t.id == tx.id);
      _selectedIds.remove(tx.id);
    });
    await AppDatabase.instance.deleteTransaction(tx.id!);
    widget.onChanged();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('Deleted "${tx.title}"'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () async {
            await AppDatabase.instance.insertTransaction(tx);
            widget.onChanged();
          },
        ),
      ));
  }

  void _toggleSelect(int id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
  }

  void _clearSelection() => setState(() => _selectedIds.clear());

  /// Sum of stored amounts (split share already applied) for selected transactions.
  double get _sumMyShare {
    return _transactions
        .where((tx) => _selectedIds.contains(tx.id) && tx.isExpense)
        .fold(0.0, (acc, tx) => acc + tx.amount);
  }

  /// Sum of original (pre-split) amounts for selected transactions.
  double get _sumFullTotal {
    return _transactions
        .where((tx) => _selectedIds.contains(tx.id) && tx.isExpense)
        .fold(0.0, (acc, tx) {
          final split = _parseSplitNote(tx.note);
          return acc + (split?.originalAmount ?? tx.amount);
        });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    if (_transactions.isEmpty) {
      return const Center(child: Text('No transactions yet.'));
    }

    final myShare = _sumMyShare;

    return Column(
      children: [
        // --- Selection header bar ---
        if (_isSelecting)
          Container(
            color: Theme.of(context).colorScheme.secondaryContainer,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: _clearSelection,
                  tooltip: 'Clear selection',
                ),
                Text(
                  '${_selectedIds.length} selected',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                ),
                const Spacer(),
                TextButton.icon(
                  icon: const Icon(Icons.select_all, size: 18),
                  label: const Text('All'),
                  onPressed: () => setState(() {
                    _selectedIds.addAll(_transactions.map((t) => t.id!));
                  }),
                ),
              ],
            ),
          ),

        // --- Transaction list ---
        Expanded(
          child: ListView.separated(
            itemCount: _transactions.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final tx = _transactions[i];
              final isSelected = _selectedIds.contains(tx.id);
              final split = _parseSplitNote(tx.note);

              final tile = ListTile(
                selected: isSelected,
                selectedTileColor: Theme.of(context).colorScheme.primaryContainer.withOpacity(0.35),
                onTap: () {
                  if (_isSelecting) {
                    _toggleSelect(tx.id!);
                  } else {
                    widget.onEdit(tx);
                  }
                },
                onLongPress: () => _toggleSelect(tx.id!),
                leading: _isSelecting
                    ? Checkbox(
                        value: isSelected,
                        onChanged: (_) => _toggleSelect(tx.id!),
                      )
                    : null,
                title: Row(children: [
                  Expanded(child: Text(tx.title, overflow: TextOverflow.ellipsis)),
                  if (split != null) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text('÷${split.count}', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                    ),
                  ],
                ]),
                subtitle: Text('${DateFormat('MMM dd, yyyy').format(tx.date)} • ${tx.paymentMethod}'),
                trailing: split != null
                    ? Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            '-${widget.currency}${_money(tx.amount)}',
                            style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold, fontSize: 14),
                          ),
                          Text(
                            'of ${widget.currency}${_money(split.originalAmount)}',
                            style: TextStyle(fontSize: 10, color: Theme.of(context).colorScheme.outline),
                          ),
                        ],
                      )
                    : Text(
                        '${tx.isExpense ? '-' : '+'}${widget.currency}${_money(tx.amount)}',
                        style: TextStyle(
                          color: tx.isExpense ? Colors.redAccent : Colors.green[700],
                          fontWeight: FontWeight.bold,
                        ),
                      ),
              );

              // Disable swipe-to-delete while selecting
              if (_isSelecting) return tile;

              return Dismissible(
                key: Key('all_tx_${tx.id}'),
                direction: DismissDirection.endToStart,
                background: Container(
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 20),
                  color: Colors.red,
                  child: const Icon(Icons.delete, color: Colors.white),
                ),
                onDismissed: (_) => _deleteWithUndo(tx),
                child: tile,
              );
            },
          ),
        ),

        // --- Summary bottom bar ---
        if (_isSelecting)
          Container(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 8, offset: const Offset(0, -2))],
            ),
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_selectedIds.length} item${_selectedIds.length == 1 ? '' : 's'} selected',
                  style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.outline),
                ),
                const SizedBox(height: 8),
                IntrinsicHeight(
                  child: Row(
                    children: [
                      // My expense column
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('My expense', style: TextStyle(fontSize: 11, color: Colors.grey)),
                            Text(
                              '${widget.currency}${_money(myShare)}',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      // Vertical divider
                      VerticalDivider(
                        width: 24,
                        thickness: 1,
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                      // Total original column
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Total (original)', style: TextStyle(fontSize: 11, color: Colors.grey)),
                            Text(
                              '${widget.currency}${_money(_sumFullTotal)}',
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                color: Colors.redAccent,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

      ],
    );
  }
}


// ==========================================
// 7. AI CHAT SCREEN (PENNY)
// ==========================================

class _RichChatText extends StatelessWidget {
  final String text;
  final TextStyle style;
  final bool markup;
  const _RichChatText({required this.text, required this.style, required this.markup});

  @override
  Widget build(BuildContext context) {
    if (!markup) return Text(text, style: style);

    final spans = <TextSpan>[];
    final re = RegExp(r'\*\*(.+?)\*\*|\*(.+?)\*');
    var last = 0;
    for (final m in re.allMatches(text)) {
      if (m.start > last) spans.add(TextSpan(text: text.substring(last, m.start)));
      if (m.group(1) != null) {
        spans.add(TextSpan(text: m.group(1), style: const TextStyle(fontWeight: FontWeight.bold)));
      } else {
        spans.add(TextSpan(text: m.group(2), style: const TextStyle(fontStyle: FontStyle.italic)));
      }
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    return Text.rich(TextSpan(style: style, children: spans));
  }
}

class AiChatScreen extends StatefulWidget {
  final String currency;
  final VoidCallback onExpenseLogged;

  const AiChatScreen({super.key, required this.currency, required this.onExpenseLogged});

  @override
  State<AiChatScreen> createState() => _AiChatScreenState();
}

class _AiChatScreenState extends State<AiChatScreen> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final List<ChatMessage> _messages = [];
  final Map<ChatMessage, PendingExpense> _pending = Map<ChatMessage, PendingExpense>.identity();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadChat();
  }

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _loadChat() async {
    final history = await AppDatabase.instance.getRecentChatMessages();
    if (!mounted) return;
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
    _scrollToEnd();
  }

  Future<void> _addAssistant(AdvisorReply reply) async {
    final aiMsg = ChatMessage(sender: ChatSender.assistant, content: reply.text, timestamp: DateTime.now());
    await AppDatabase.instance.insertChatMessage(aiMsg);
    if (!mounted) return;
    setState(() {
      _messages.add(aiMsg);
      if (reply.pending != null) _pending[aiMsg] = reply.pending!;
    });
    _scrollToEnd();

    if (reply.loggedTxId != null) {
      widget.onExpenseLogged();
      _showUndo(reply.loggedTxId!);
    }
  }

  void _showUndo(int txId) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: const Text('Expense logged'),
        duration: const Duration(seconds: 6),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () async {
            await AppDatabase.instance.deleteTransaction(txId);
            widget.onExpenseLogged();
            if (mounted) {
              await _addAssistant(const AdvisorReply('↩️ Undone — that expense was removed.'));
            }
          },
        ),
      ));
  }

  Future<void> _send(String text) async {
    final query = text.trim();
    if (query.isEmpty || _busy) return;
    _controller.clear();

    final userMsg = ChatMessage(sender: ChatSender.user, content: query, timestamp: DateTime.now());
    setState(() {
      _messages.add(userMsg);
      _busy = true;
    });
    _scrollToEnd();
    await AppDatabase.instance.insertChatMessage(userMsg);

    final reply = await AiAdvisorService.processUserMessage(query);
    if (mounted) setState(() => _busy = false);
    await _addAssistant(reply);
  }

  Future<void> _confirmPending(ChatMessage m) async {
    final p = _pending.remove(m);
    if (p == null) return;
    setState(() {});
    final reply = await AiAdvisorService.logExpense(p.title, p.amount);
    await _addAssistant(reply);
  }

  Future<void> _cancelPending(ChatMessage m) async {
    if (_pending.remove(m) == null) return;
    setState(() {});
    await _addAssistant(const AdvisorReply("No problem — I didn't log anything."));
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
            controller: _scroll,
            padding: const EdgeInsets.all(16),
            itemCount: _messages.length,
            itemBuilder: (context, i) {
              final m = _messages[i];
              final isUser = m.sender == ChatSender.user;
              final pending = _pending[m];
              final scheme = Theme.of(context).colorScheme;

              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Align(
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
                              color: isUser ? scheme.primary : scheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: _RichChatText(
                              text: m.content,
                              markup: !isUser,
                              style: TextStyle(
                                color: isUser ? scheme.onPrimary : scheme.onSurface,
                                fontSize: 14,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (pending != null)
                    Padding(
                      padding: const EdgeInsets.only(left: 36, bottom: 6),
                      child: Wrap(
                        spacing: 8,
                        children: [
                          FilledButton.tonalIcon(
                            icon: const Icon(Icons.check, size: 18),
                            label: Text('Log ${widget.currency}${_money(pending.amount)}'),
                            onPressed: () => _confirmPending(m),
                          ),
                          TextButton(onPressed: () => _cancelPending(m), child: const Text('Cancel')),
                        ],
                      ),
                    ),
                ],
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
  late final TextEditingController _noteController;
  late DateTime _selectedDate;
  List<Category> _categories = [];
  Category? _selectedCategory;
  String _paymentMethod = 'Cash';
  String _cardName = '';
  List<String> _debitCards = [];
  List<String> _creditCards = [];
  bool _splitEnabled = false;
  int _splitCount = 2;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.existing?.title ?? '');

    // Restore split state if editing an existing split transaction
    final existingSplit = _parseSplitNote(widget.existing?.note);
    if (existingSplit != null && widget.existing != null) {
      // Amount field shows the original total, not the user's share
      _amountController = TextEditingController(text: existingSplit.originalAmount.toString());
      _splitEnabled = true;
      _splitCount = existingSplit.count;
      _noteController = TextEditingController(text: existingSplit.userNote ?? '');
    } else {
      _amountController = TextEditingController(text: widget.existing != null ? widget.existing!.amount.toString() : '');
      _noteController = TextEditingController(text: widget.existing?.note ?? '');
    }

    _selectedDate = widget.existing?.date ?? DateTime.now();
    final rawMethod = widget.existing?.paymentMethod ?? 'Cash';
    if (rawMethod.startsWith('Debit Card - ')) {
      _paymentMethod = 'Debit Card';
      _cardName = rawMethod.substring('Debit Card - '.length);
    } else if (rawMethod.startsWith('Credit Card - ')) {
      _paymentMethod = 'Credit Card';
      _cardName = rawMethod.substring('Credit Card - '.length);
    } else {
      _paymentMethod = rawMethod;
    }
    _fetchCategories();
    _loadKnownCards();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _amountController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _fetchCategories() async {
    final list = await AppDatabase.instance.getAllCategories();
    if (!mounted) return;
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

  Future<void> _loadKnownCards() async {
    final transactions = await AppDatabase.instance.getAllTransactions();
    if (!mounted) return;
    final debit = <String>{};
    final credit = <String>{};
    for (final tx in transactions) {
      if (tx.paymentMethod.startsWith('Debit Card - ')) {
        debit.add(tx.paymentMethod.substring('Debit Card - '.length));
      } else if (tx.paymentMethod.startsWith('Credit Card - ')) {
        credit.add(tx.paymentMethod.substring('Credit Card - '.length));
      }
    }
    if (mounted) {
      setState(() {
        _debitCards = debit.toList()..sort();
        _creditCards = credit.toList()..sort();
      });
    }
  }

  void _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(now.year - 5, now.month, now.day),
      lastDate: DateTime(now.year + 1, 12, 31),
    );
    if (picked != null && mounted) {
      setState(() => _selectedDate = picked);
    }
  }

  Future<void> _save() async {
    final title = _titleController.text.trim();
    final amount = double.tryParse(_amountController.text.trim().replaceAll(',', '')) ?? 0.0;
    final noteText = _noteController.text.trim();

    if (title.isEmpty || amount <= 0 || _selectedCategory == null) return;

    // Apply split: save only the user's share, but encode original amount in note
    final isSplit = _splitEnabled && _splitCount > 1;
    final effectiveAmount = isSplit ? amount / _splitCount : amount;
    // Keep original title (no ÷ suffix in title — info is in the note prefix instead)
    final effectiveTitle = title;
    // Encode split info as a prefix in the note: [split:N:originalAmount]
    final splitPrefix = isSplit ? '[split:$_splitCount:${amount.toStringAsFixed(2)}]' : '';
    final effectiveNote = isSplit
        ? (noteText.isEmpty ? splitPrefix : '$splitPrefix$noteText')
        : (noteText.isEmpty ? null : noteText);
    final paymentMethod = (_paymentMethod == 'Debit Card' || _paymentMethod == 'Credit Card') && _cardName.trim().isNotEmpty
        ? '$_paymentMethod - ${_cardName.trim()}'
        : _paymentMethod;

    final nav = Navigator.of(context);
    final timeSource = widget.existing?.date ?? DateTime.now();
    final dateTime = DateTime(_selectedDate.year, _selectedDate.month, _selectedDate.day, timeSource.hour, timeSource.minute);

    if (widget.existing == null) {
      await AppDatabase.instance.insertTransaction(ExpenseTransaction(
        title: effectiveTitle,
        amount: effectiveAmount,
        date: dateTime,
        categoryId: _selectedCategory!.id!,
        paymentMethod: paymentMethod,
        note: effectiveNote,
      ));
    } else {
      await AppDatabase.instance.updateTransaction(ExpenseTransaction(
        id: widget.existing!.id,
        title: effectiveTitle,
        amount: effectiveAmount,
        date: dateTime,
        categoryId: _selectedCategory!.id!,
        paymentMethod: paymentMethod,
        note: effectiveNote,
      ));
    }

    if (mounted) nav.pop(true);
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
            // --- Split Expense Toggle ---
            SwitchListTile.adaptive(
              title: const Text('Split Expense'),
              subtitle: const Text('Divide total equally among people'),
              value: _splitEnabled,
              onChanged: (v) => setState(() {
                _splitEnabled = v;
                if (!v) _splitCount = 2;
              }),
              contentPadding: EdgeInsets.zero,
              dense: true,
            ),
            if (_splitEnabled) ...[
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _amountController,
                builder: (context, amtValue, _) {
                  final total = double.tryParse(amtValue.text.trim().replaceAll(',', '')) ?? 0.0;
                  final share = _splitCount > 1 ? total / _splitCount : total;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          const Text('Split between:', style: TextStyle(fontWeight: FontWeight.w500)),
                          const Spacer(),
                          IconButton(
                            icon: const Icon(Icons.remove_circle_outline),
                            onPressed: _splitCount > 2 ? () => setState(() => _splitCount--) : null,
                          ),
                          Text(
                            '$_splitCount people',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                          ),
                          IconButton(
                            icon: const Icon(Icons.add_circle_outline),
                            onPressed: _splitCount < 20 ? () => setState(() => _splitCount++) : null,
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('Your share', style: TextStyle(fontSize: 12)),
                                Text(
                                  '${widget.currency}${_money(share)}',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 22,
                                    color: Theme.of(context).colorScheme.primary,
                                  ),
                                ),
                              ],
                            ),
                            if (total > 0)
                              Text(
                                '${widget.currency}${_money(total)} ÷ $_splitCount',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                  );
                },
              ),
            ],
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
                    onChanged: (v) => setState(() {
                      _paymentMethod = v ?? 'Cash';
                      _cardName = '';
                    }),
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
            if (_paymentMethod == 'Debit Card' || _paymentMethod == 'Credit Card') ...[
              const SizedBox(height: 12),
              Autocomplete<String>(
                key: ValueKey(_paymentMethod),
                initialValue: TextEditingValue(text: _cardName),
                optionsBuilder: (TextEditingValue textEditingValue) {
                  final known = _paymentMethod == 'Debit Card' ? _debitCards : _creditCards;
                  if (textEditingValue.text.isEmpty) return known;
                  return known
                      .where((n) => n.toLowerCase().contains(textEditingValue.text.toLowerCase()))
                      .toList();
                },
                onSelected: (String selection) => setState(() => _cardName = selection),
                fieldViewBuilder: (context, controller, focusNode, onSubmitted) {
                  return TextField(
                    controller: controller,
                    focusNode: focusNode,
                    decoration: InputDecoration(
                      labelText: '$_paymentMethod Name',
                      hintText: 'e.g. BDO, BPI, Metrobank...',
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.credit_card_outlined),
                    ),
                    onChanged: (v) => _cardName = v,
                  );
                },
              ),
            ],
            const SizedBox(height: 12),
            TextField(controller: _noteController, decoration: const InputDecoration(labelText: 'Note (optional)', border: OutlineInputBorder())),
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
