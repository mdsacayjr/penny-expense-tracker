import 'dart:async';
import 'package:flutter/material.dart';
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

  factory ExpenseTransaction.fromMap(Map<String, dynamic> map) => ExpenseTransaction(
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
// 2. LOCAL SQLITE DATABASE
// ==========================================

class AppDatabase {
  static final AppDatabase instance = AppDatabase._init();
  static Database? _database;

  AppDatabase._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('expense_tracker.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final fullPath = p.join(dbPath, filePath);
    return await openDatabase(fullPath, version: 1, onCreate: _createDB);
  }

  Future<void> _createDB(Database db, int version) async {
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
    await _seedDefaultCategories(db);
  }

  Future<void> _seedDefaultCategories(Database db) async {
    final defaultCategories = [
      {'name': 'Food & Dining', 'icon_code_point': 0xe532, 'color_value': 0xFFFF7043, 'monthly_budget': 400.0, 'is_expense': 1},
      {'name': 'Groceries', 'icon_code_point': 0xe3ab, 'color_value': 0xFF66BB6A, 'monthly_budget': 350.0, 'is_expense': 1},
      {'name': 'Transportation', 'icon_code_point': 0xe1d7, 'color_value': 0xFF42A5F5, 'monthly_budget': 150.0, 'is_expense': 1},
      {'name': 'Utilities & Bills', 'icon_code_point': 0xe56c, 'color_value': 0xFFFFA726, 'monthly_budget': 200.0, 'is_expense': 1},
      {'name': 'Entertainment', 'icon_code_point': 0xe40f, 'color_value': 0xFFAB47BC, 'monthly_budget': 100.0, 'is_expense': 1},
      {'name': 'Health', 'icon_code_point': 0xe3e3, 'color_value': 0xFFEF5350, 'monthly_budget': 100.0, 'is_expense': 1},
      {'name': 'Salary / Income', 'icon_code_point': 0xe041, 'color_value': 0xFF26A69A, 'monthly_budget': 0.0, 'is_expense': 0},
    ];

    for (final cat in defaultCategories) {
      await db.insert('categories', cat);
    }
  }

  Future<int> insertTransaction(ExpenseTransaction tx) async {
    final db = await database;
    return await db.insert('transactions', tx.toMap());
  }

  Future<List<ExpenseTransaction>> getAllTransactions({int limit = 100}) async {
    final db = await database;
    final maps = await db.query('transactions', orderBy: 'date DESC', limit: limit);
    return maps.map((e) => ExpenseTransaction.fromMap(e)).toList();
  }

  Future<List<Category>> getAllCategories() async {
    final db = await database;
    final maps = await db.query('categories', orderBy: 'id ASC');
    return maps.map((e) => Category.fromMap(e)).toList();
  }

  Future<int> insertChatMessage(ChatMessage msg) async {
    final db = await database;
    return await db.insert('chat_messages', msg.toMap());
  }

  Future<List<ChatMessage>> getRecentChatMessages({int limit = 50}) async {
    final db = await database;
    final maps = await db.query('chat_messages', orderBy: 'timestamp ASC', limit: limit);
    return maps.map((e) => ChatMessage.fromMap(e)).toList();
  }

  Future<List<Map<String, dynamic>>> getCategorySpendingSummary(DateTime startDate, DateTime endDate) async {
    final db = await database;
    return await db.rawQuery('''
      SELECT 
        c.name AS category_name,
        c.monthly_budget AS budget,
        c.color_value AS color,
        SUM(t.amount) AS total_spent
      FROM transactions t
      JOIN categories c ON t.category_id = c.id
      WHERE t.is_expense = 1 AND t.date >= ? AND t.date <= ?
      GROUP BY c.id
      ORDER BY total_spent DESC
    ''', [startDate.millisecondsSinceEpoch, endDate.millisecondsSinceEpoch]);
  }

  Future<String> buildFinancialContextForAI() async {
    final now = DateTime.now();
    final firstDayOfMonth = DateTime(now.year, now.month, 1);
    final summary = await getCategorySpendingSummary(firstDayOfMonth, now);

    double totalSpent = 0;
    final categoryLines = <String>[];

    for (final row in summary) {
      final name = row['category_name'];
      final spent = (row['total_spent'] as num).toDouble();
      final budget = (row['budget'] as num).toDouble();
      totalSpent += spent;

      categoryLines.add('- $name: Spent \$${spent.toStringAsFixed(2)} ${budget > 0 ? "(Budget: \$${budget.toStringAsFixed(2)})" : ""}');
    }

    return '''
[CURRENT FINANCIAL SNAPSHOT]
Date: ${now.toIso8601String().substring(0, 10)}
Month-to-Date Total Expenses: \$${totalSpent.toStringAsFixed(2)}
Category Breakdown:
${categoryLines.isEmpty ? "- No expenses recorded this month yet." : categoryLines.join('\n')}
''';
  }
}

// ==========================================
// 3. AI ADVISOR & GUARDRAILS
// ==========================================

class AiAdvisorService {
  static Future<String> generateAdvice(String userQuery) async {
    final lower = userQuery.toLowerCase();
    final offTopicKeywords = ['python', 'javascript', 'write code', 'who won', 'joke', 'weather', 'recipe', 'history'];

    for (final word in offTopicKeywords) {
      if (lower.contains(word)) {
        return "I am Penny, your dedicated offline expense assistant. I can only assist with your budget, transactions, and spending decisions.";
      }
    }

    final snapshot = await AppDatabase.instance.buildFinancialContextForAI();
    await Future.delayed(const Duration(milliseconds: 500)); // Local processing simulation

    if (lower.contains('afford')) {
      return "Based on your spending this month, review your remaining budget carefully. If this isn't essential, saving the money helps protect your monthly target!";
    } else if (lower.contains('summary') || lower.contains('how much')) {
      return "Here is your current spending overview:\n\n$snapshot";
    } else if (lower.contains('save') || lower.contains('cut down')) {
      return "To save money this month, target your highest expense category shown in your breakdown. Cutting back just 10% there gives immediate savings!";
    } else {
      return "I've reviewed your spending records. How else can I assist you with your budget or expenses today?";
    }
  }
}

// ==========================================
// 4. MAIN APP SHELL & NAVIGATION
// ==========================================

class OfflineExpenseApp extends StatelessWidget {
  const OfflineExpenseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Penny AI Expense Tracker',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1E88E5),
          brightness: Brightness.light,
        ),
      ),
      home: const MainNavigationShell(),
    );
  }
}

class MainNavigationShell extends StatefulWidget {
  const MainNavigationShell({super.key});

  @override
  State<MainNavigationShell> createState() => _MainNavigationShellState();
}

class _MainNavigationShellState extends State<MainNavigationShell> {
  int _currentIndex = 0;
  final GlobalKey<_DashboardScreenState> _dashboardKey = GlobalKey();

  void _openAddTransactionModal() async {
    final added = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => const AddTransactionDialog(),
    );

    if (added == true) {
      _dashboardKey.currentState?.loadData();
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final screens = [
      DashboardScreen(key: _dashboardKey),
      const TransactionsScreen(),
      const AiChatScreen(),
    ];

    return Scaffold(
      body: IndexedStack(index: _currentIndex, children: screens),
      floatingActionButton: _currentIndex != 2
          ? FloatingActionButton.extended(
              onPressed: _openAddTransactionModal,
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
          NavigationDestination(icon: Icon(Icons.smart_toy_outlined), selectedIcon: Icon(Icons.smart_toy), label: 'AI Advisor'),
        ],
      ),
    );
  }
}

// ==========================================
// 5. DASHBOARD SCREEN
// ==========================================

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
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

    final summary = await AppDatabase.instance.getCategorySpendingSummary(firstDay, now);
    final recent = await AppDatabase.instance.getAllTransactions(limit: 5);

    double total = 0.0;
    for (var item in summary) {
      total += (item['total_spent'] as num).toDouble();
    }

    if (mounted) {
      setState(() {
        _summary = summary;
        _totalExpenses = total;
        _recent = recent;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    return Scaffold(
      appBar: AppBar(title: const Text('Monthly Overview')),
      body: RefreshIndicator(
        onRefresh: loadData,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              color: Theme.of(context).colorScheme.primaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Total Spent This Month', style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 8),
                    Text(
                      NumberFormat.simpleCurrency().format(_totalExpenses),
                      style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            if (_summary.isNotEmpty) ...[
              Text('Spending Breakdown', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
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
                        title: '\$${spent.toStringAsFixed(0)}',
                        radius: 50,
                        titleStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white),
                      );
                    }).toList(),
                  ),
                ),
              ),
              const SizedBox(height: 20),
            ],
            Text('Recent Expenses', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            if (_recent.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 30),
                child: Center(child: Text('No expenses recorded yet. Tap + to add!')),
              )
            else
              ..._recent.map((tx) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const CircleAvatar(child: Icon(Icons.receipt)),
                    title: Text(tx.title),
                    subtitle: Text(DateFormat('MMM dd, yyyy').format(tx.date)),
                    trailing: Text(
                      '-${NumberFormat.simpleCurrency().format(tx.amount)}',
                      style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.redAccent),
                    ),
                  )),
            const SizedBox(height: 60),
          ],
        ),
      ),
    );
  }
}

// ==========================================
// 6. TRANSACTIONS SCREEN
// ==========================================

class TransactionsScreen extends StatefulWidget {
  const TransactionsScreen({super.key});

  @override
  State<TransactionsScreen> createState() => _TransactionsScreenState();
}

class _TransactionsScreenState extends State<TransactionsScreen> {
  List<ExpenseTransaction> _transactions = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final list = await AppDatabase.instance.getAllTransactions(limit: 100);
    if (mounted) setState(() { _transactions = list; _loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('All Transactions')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _transactions.isEmpty
              ? const Center(child: Text('No transactions yet.'))
              : ListView.separated(
                  itemCount: _transactions.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final tx = _transactions[i];
                    return ListTile(
                      title: Text(tx.title),
                      subtitle: Text('${DateFormat('MMM dd, yyyy').format(tx.date)} • ${tx.paymentMethod}'),
                      trailing: Text(
                        '-${NumberFormat.simpleCurrency().format(tx.amount)}',
                        style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold),
                      ),
                    );
                  },
                ),
    );
  }
}

// ==========================================
// 7. AI CHAT SCREEN
// ==========================================

class AiChatScreen extends StatefulWidget {
  const AiChatScreen({super.key});

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
            content: "Hello! I'm Penny, your offline expense assistant. Ask me about your spending, monthly budget, or whether you can afford an upcoming expense.",
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

    final reply = await AiAdvisorService.generateAdvice(query);
    final aiMsg = ChatMessage(sender: ChatSender.assistant, content: reply, timestamp: DateTime.now());
    await AppDatabase.instance.insertChatMessage(aiMsg);

    if (mounted) setState(() { _messages.add(aiMsg); _busy = false; });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Penny (Offline AI)')),
      body: Column(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                ActionChip(label: const Text('Monthly Summary'), onPressed: () => _send('Give me a summary of my spending this month.')),
                const SizedBox(width: 8),
                ActionChip(label: const Text('How to save \$50?'), onPressed: () => _send('Where can I cut down to save \$50 this month?')),
                const SizedBox(width: 8),
                ActionChip(label: const Text('Can I afford dinner?'), onPressed: () => _send('Can I afford a \$30 dinner tonight?')),
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
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: isUser ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.surfaceVariant,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(
                      m.content,
                      style: TextStyle(color: isUser ? Theme.of(context).colorScheme.onPrimary : Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                  ),
                );
              },
            ),
          ),
          if (_busy) const Padding(padding: EdgeInsets.all(8), child: Text('Penny is thinking...', style: TextStyle(fontSize: 12))),
          SafeArea(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      decoration: const InputDecoration(hintText: 'Ask about expenses...', border: InputBorder.none),
                      onSubmitted: _send,
                    ),
                  ),
                  IconButton(icon: const Icon(Icons.send), onPressed: () => _send(_controller.text)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ==========================================
// 8. ADD TRANSACTION MODAL
// ==========================================

class AddTransactionDialog extends StatefulWidget {
  const AddTransactionDialog({super.key});

  @override
  State<AddTransactionDialog> createState() => _AddTransactionDialogState();
}

class _AddTransactionDialogState extends State<AddTransactionDialog> {
  final _titleController = TextEditingController();
  final _amountController = TextEditingController();
  List<Category> _categories = [];
  Category? _selectedCategory;
  String _paymentMethod = 'Cash';

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    final list = await AppDatabase.instance.getAllCategories();
    setState(() {
      _categories = list.where((c) => c.isExpense).toList();
      if (_categories.isNotEmpty) _selectedCategory = _categories.first;
    });
  }

  Future<void> _save() async {
    final title = _titleController.text.trim();
    final amount = double.tryParse(_amountController.text.trim()) ?? 0.0;

    if (title.isEmpty || amount <= 0 || _selectedCategory == null) return;

    final tx = ExpenseTransaction(
      title: title,
      amount: amount,
      date: DateTime.now(),
      categoryId: _selectedCategory!.id!,
      paymentMethod: _paymentMethod,
    );

    await AppDatabase.instance.insertTransaction(tx);
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.only(left: 20, right: 20, top: 24, bottom: MediaQuery.of(context).viewInsets.bottom + 24),
      decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface, borderRadius: const BorderRadius.vertical(top: Radius.circular(24))),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Add Expense', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          TextField(controller: _titleController, decoration: const InputDecoration(labelText: 'Expense Name', border: OutlineInputBorder())),
          const SizedBox(height: 10),
          TextField(controller: _amountController, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Amount (\$)', border: OutlineInputBorder())),
          const SizedBox(height: 10),
          if (_categories.isNotEmpty)
            DropdownButtonFormField<Category>(
              value: _selectedCategory,
              decoration: const InputDecoration(labelText: 'Category', border: OutlineInputBorder()),
              items: _categories.map((c) => DropdownMenuItem(value: c, child: Text(c.name))).toList(),
              onChanged: (v) => setState(() => _selectedCategory = v),
            ),
          const SizedBox(height: 16),
          FilledButton.icon(onPressed: _save, icon: const Icon(Icons.check), label: const Text('Save Expense')),
        ],
      ),
    );
  }
}
