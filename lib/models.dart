// 對應 feixu_api.py 回傳的 JSON 結構。
// 之所以每個欄位都用 num? / String? 這種寬鬆型別，是因為後端有些欄位
// 在特定狀況下會是 null（例如查不到現價、或還沒有任何事件），前端要能安全處理。

class FeixuSnapshot {
  final String code;
  final String name;
  final double price;
  final double change;
  final double changePct;
  final bool tradable;
  final String? statusNote;

  FeixuSnapshot({
    required this.code,
    required this.name,
    required this.price,
    required this.change,
    required this.changePct,
    required this.tradable,
    required this.statusNote,
  });

  factory FeixuSnapshot.fromJson(Map<String, dynamic> json) {
    return FeixuSnapshot(
      code: json['code'] as String,
      name: json['name'] as String,
      price: (json['price'] as num).toDouble(),
      change: (json['change'] as num).toDouble(),
      changePct: (json['change_pct'] as num).toDouble(),
      tradable: json['tradable'] as bool,
      statusNote: json['status_note'] as String?,
    );
  }

  bool get isUp => change >= 0;
}

class ChartPoint {
  final DateTime time;
  final double price;

  ChartPoint({required this.time, required this.price});

  factory ChartPoint.fromJson(Map<String, dynamic> json) {
    return ChartPoint(
      time: DateTime.parse(json['time'] as String),
      price: (json['price'] as num).toDouble(),
    );
  }
}

class ChartEvent {
  final DateTime time;
  final String type; // black_swan / great_news / volatility

  ChartEvent({required this.time, required this.type});

  factory ChartEvent.fromJson(Map<String, dynamic> json) {
    return ChartEvent(
      time: DateTime.parse(json['time'] as String),
      type: json['type'] as String,
    );
  }

  String get label {
    switch (type) {
      case 'black_swan':
        return '黑天鵝';
      case 'great_news':
        return '利多';
      case 'volatility':
        return '亂流';
      default:
        return '事件';
    }
  }
}

class FeixuChart {
  final List<ChartPoint> points;
  final List<ChartEvent> events;
  final double change;
  final double changePct;

  FeixuChart({
    required this.points,
    required this.events,
    required this.change,
    required this.changePct,
  });

  factory FeixuChart.fromJson(Map<String, dynamic> json) {
    return FeixuChart(
      points: (json['points'] as List)
          .map((p) => ChartPoint.fromJson(p as Map<String, dynamic>))
          .toList(),
      events: (json['events'] as List)
          .map((e) => ChartEvent.fromJson(e as Map<String, dynamic>))
          .toList(),
      change: (json['change'] as num).toDouble(),
      changePct: (json['change_pct'] as num).toDouble(),
    );
  }
}

class Holding {
  final String code;
  final String name;
  final String unit;
  final int lots;
  final double avgCost;
  final double? price;
  final double? marketValue;
  final double? unrealizedPnl;
  final double? unrealizedPnlPct;

  Holding({
    required this.code,
    required this.name,
    required this.unit,
    required this.lots,
    required this.avgCost,
    required this.price,
    required this.marketValue,
    required this.unrealizedPnl,
    required this.unrealizedPnlPct,
  });

  factory Holding.fromJson(Map<String, dynamic> json) {
    num? asNum(dynamic v) => v == null ? null : v as num;
    return Holding(
      code: json['code'] as String,
      name: json['name'] as String,
      unit: json['unit'] as String,
      lots: json['lots'] as int,
      avgCost: (json['avg_cost'] as num).toDouble(),
      price: asNum(json['price'])?.toDouble(),
      marketValue: asNum(json['market_value'])?.toDouble(),
      unrealizedPnl: asNum(json['unrealized_pnl'])?.toDouble(),
      unrealizedPnlPct: asNum(json['unrealized_pnl_pct'])?.toDouble(),
    );
  }
}

class Portfolio {
  final double cash;
  final double realizedPnl;
  final List<Holding> holdings;
  final double totalMarketValue;
  final double totalUnrealizedPnl;
  final double totalAssets;

  Portfolio({
    required this.cash,
    required this.realizedPnl,
    required this.holdings,
    required this.totalMarketValue,
    required this.totalUnrealizedPnl,
    required this.totalAssets,
  });

  factory Portfolio.fromJson(Map<String, dynamic> json) {
    return Portfolio(
      cash: (json['cash'] as num).toDouble(),
      realizedPnl: (json['realized_pnl'] as num).toDouble(),
      holdings: (json['holdings'] as List)
          .map((h) => Holding.fromJson(h as Map<String, dynamic>))
          .toList(),
      totalMarketValue: (json['total_market_value'] as num).toDouble(),
      totalUnrealizedPnl: (json['total_unrealized_pnl'] as num).toDouble(),
      totalAssets: (json['total_assets'] as num).toDouble(),
    );
  }
}

class TradeResult {
  final bool ok;
  final String message;

  TradeResult({required this.ok, required this.message});

  factory TradeResult.fromJson(Map<String, dynamic> json) {
    return TradeResult(ok: json['ok'] as bool, message: json['message'] as String);
  }
}

class BossDamageEntry {
  final String userId;
  final int damage;

  BossDamageEntry({required this.userId, required this.damage});

  factory BossDamageEntry.fromJson(Map<String, dynamic> json) {
    return BossDamageEntry(userId: json['user_id'] as String, damage: json['damage'] as int);
  }
}

class BossStatus {
  final bool active;
  final int? maxHp;
  final int? currentHp;
  final double? prizePool;
  final DateTime? endsAt;
  final int? bombCost;
  final int? bombDamage;
  final List<BossDamageEntry> topDamage;
  final DateTime? nextSpawnEta;

  BossStatus({
    required this.active,
    this.maxHp,
    this.currentHp,
    this.prizePool,
    this.endsAt,
    this.bombCost,
    this.bombDamage,
    this.topDamage = const [],
    this.nextSpawnEta,
  });

  factory BossStatus.fromJson(Map<String, dynamic> json) {
    if (json['active'] != true) {
      return BossStatus(
        active: false,
        nextSpawnEta: json['next_spawn_eta'] != null
            ? DateTime.parse(json['next_spawn_eta'] as String)
            : null,
      );
    }
    return BossStatus(
      active: true,
      maxHp: json['max_hp'] as int,
      currentHp: json['current_hp'] as int,
      prizePool: (json['prize_pool'] as num).toDouble(),
      endsAt: DateTime.parse(json['ends_at'] as String),
      bombCost: json['bomb_cost'] as int,
      bombDamage: json['bomb_damage'] as int,
      topDamage: (json['top_damage'] as List)
          .map((e) => BossDamageEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

class BossAttackResult {
  final bool ok;
  final String message;
  final bool defeated;
  final BossStatus status;

  BossAttackResult({
    required this.ok,
    required this.message,
    required this.defeated,
    required this.status,
  });

  factory BossAttackResult.fromJson(Map<String, dynamic> json) {
    return BossAttackResult(
      ok: json['ok'] as bool,
      message: json['message'] as String,
      defeated: json['defeated'] as bool,
      status: BossStatus.fromJson(json['status'] as Map<String, dynamic>),
    );
  }
}
