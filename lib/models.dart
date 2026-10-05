import 'package:flutter/painting.dart' show Color;

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

class LeaderboardEntry {
  final String userId;
  final String? name;
  final double totalAssets;

  LeaderboardEntry({required this.userId, this.name, required this.totalAssets});

  String get displayName => (name != null && name!.isNotEmpty) ? name! : userId;

  factory LeaderboardEntry.fromJson(Map<String, dynamic> json) {
    return LeaderboardEntry(
      userId: json['user_id'] as String,
      name: json['name'] as String?,
      totalAssets: (json['total_assets'] as num).toDouble(),
    );
  }
}

class FxQuote {
  final double mid;
  final double bid;
  final double ask;
  final double ageSeconds;
  final bool open;
  final double marginPerLot;
  final int leverage;
  final DateTime quoteTime;

  FxQuote({
    required this.mid,
    required this.bid,
    required this.ask,
    required this.ageSeconds,
    required this.open,
    required this.marginPerLot,
    required this.leverage,
    required this.quoteTime,
  });

  factory FxQuote.fromJson(Map<String, dynamic> j) => FxQuote(
        mid: (j['mid'] as num).toDouble(),
        bid: (j['bid'] as num).toDouble(),
        ask: (j['ask'] as num).toDouble(),
        ageSeconds: (j['age_seconds'] as num).toDouble(),
        open: j['open'] as bool,
        marginPerLot: (j['margin_per_lot'] as num).toDouble(),
        leverage: (j['leverage'] as num).toInt(),
        quoteTime: DateTime.parse(j['quote_time'] as String),
      );
}

class FxPosition {
  final String side; // long / short
  final double lots;
  final double entry;
  final double mark;
  final double margin;
  final double unrealized;
  final double swap;
  final double equity;
  final double marginLevel;
  final double? liquidationPrice;

  FxPosition({
    required this.side,
    required this.lots,
    required this.entry,
    required this.mark,
    required this.margin,
    required this.unrealized,
    required this.swap,
    required this.equity,
    required this.marginLevel,
    required this.liquidationPrice,
  });

  factory FxPosition.fromJson(Map<String, dynamic> j) => FxPosition(
        side: j['side'] as String,
        lots: (j['lots'] as num).toDouble(),
        entry: (j['entry'] as num).toDouble(),
        mark: (j['mark'] as num).toDouble(),
        margin: (j['margin'] as num).toDouble(),
        unrealized: (j['unrealized'] as num).toDouble(),
        swap: (j['swap'] as num).toDouble(),
        equity: (j['equity'] as num).toDouble(),
        marginLevel: (j['margin_level'] as num).toDouble(),
        liquidationPrice: (j['liquidation_price'] as num?)?.toDouble(),
      );
}

class FxTradeRecord {
  final String side;
  final double lots;
  final double price;
  final double realized;
  final String kind; // open / close / liquidation
  final DateTime time;

  FxTradeRecord({
    required this.side,
    required this.lots,
    required this.price,
    required this.realized,
    required this.kind,
    required this.time,
  });

  factory FxTradeRecord.fromJson(Map<String, dynamic> j) => FxTradeRecord(
        side: j['side'] as String,
        lots: (j['lots'] as num).toDouble(),
        price: (j['price'] as num).toDouble(),
        realized: (j['realized'] as num).toDouble(),
        kind: j['kind'] as String,
        time: DateTime.parse(j['time'] as String),
      );
}

class FxAccount {
  final FxPosition? position;
  final List<FxTradeRecord> trades;

  FxAccount({required this.position, required this.trades});

  factory FxAccount.fromJson(Map<String, dynamic> j) => FxAccount(
        position: j['position'] == null ? null : FxPosition.fromJson(j['position'] as Map<String, dynamic>),
        trades: (j['trades'] as List).map((e) => FxTradeRecord.fromJson(e as Map<String, dynamic>)).toList(),
      );
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

// ===== 網頁版骰寶 =====

class SicBoBetType {
  final String key;
  final String label;
  final String shortName;
  final int payout; // 1 賠 N

  SicBoBetType({required this.key, required this.label, required this.shortName, required this.payout});
}

class SicBoHistoryItem {
  final int id;
  final List<int> dice;
  final int total;
  final bool triple;

  SicBoHistoryItem({required this.id, required this.dice, required this.total, required this.triple});

  factory SicBoHistoryItem.fromJson(Map<String, dynamic> json) => SicBoHistoryItem(
        id: json['id'] as int,
        dice: (json['dice'] as List).map((e) => e as int).toList(),
        total: json['total'] as int,
        triple: json['triple'] as bool,
      );
}

class SicBoSeat {
  final int seat;
  final String? userId; // null = 空位
  final String? name;
  final double bet; // 這局這個人押的總額
  final double? payout; // 開骰後才有：這個人這局拿回多少
  final bool isMe;

  SicBoSeat({
    required this.seat,
    required this.userId,
    required this.name,
    required this.bet,
    required this.payout,
    required this.isMe,
  });

  bool get isEmpty => userId == null;

  factory SicBoSeat.fromJson(Map<String, dynamic> json) => SicBoSeat(
        seat: json['seat'] as int,
        userId: json['user_id'] as String?,
        name: json['name'] as String?,
        bet: (json['bet'] as num).toDouble(),
        payout: (json['payout'] as num?)?.toDouble(),
        isMe: json['is_me'] as bool,
      );
}

// 桌子狀態：idle = 閒置（沒人下注，還沒開局）；open = 下注倒數中；settled = 已開骰（演出/看結果中）
enum SicBoPhase { idle, open, settled }

class SicBoState {
  final SicBoPhase phase;
  final int? roundId;
  final double secondsLeft; // open：距離截止還有幾秒
  final List<int> dice; // settled 才有
  final int total;
  final bool triple;
  final double secondsSinceSettled;
  final double revealSecondsLeft;
  final double cash;
  final int betSeconds;
  final int maxBetPerRound;
  final int idleTimeoutSeconds;
  final int? mySeat;
  final List<SicBoSeat> seats;
  final List<SicBoBetType> betTypes; // 依後端順序：大、小、單、雙、豹子
  final Map<String, double> myBets;
  final Map<String, double> myPayouts;
  final Map<String, double> poolAmount;
  final Map<String, int> poolPlayers;
  final List<SicBoHistoryItem> history;

  SicBoState({
    required this.phase,
    required this.roundId,
    required this.secondsLeft,
    required this.dice,
    required this.total,
    required this.triple,
    required this.secondsSinceSettled,
    required this.revealSecondsLeft,
    required this.cash,
    required this.betSeconds,
    required this.maxBetPerRound,
    required this.idleTimeoutSeconds,
    required this.mySeat,
    required this.seats,
    required this.betTypes,
    required this.myBets,
    required this.myPayouts,
    required this.poolAmount,
    required this.poolPlayers,
    required this.history,
  });

  bool get isIdle => phase == SicBoPhase.idle;
  bool get isOpen => phase == SicBoPhase.open;
  bool get isSettled => phase == SicBoPhase.settled;
  double get myTotalBet => myBets.values.fold(0.0, (a, b) => a + b);
  double get myTotalPayout => myPayouts.values.fold(0.0, (a, b) => a + b);

  factory SicBoState.fromJson(Map<String, dynamic> json) {
    final round = json['round'] as Map<String, dynamic>;
    final phase = switch (round['status']) {
      'open' => SicBoPhase.open,
      'settled' => SicBoPhase.settled,
      _ => SicBoPhase.idle,
    };
    final betTypes = <SicBoBetType>[];
    (json['bet_types'] as Map<String, dynamic>).forEach((k, v) {
      final m = v as Map<String, dynamic>;
      betTypes.add(SicBoBetType(
        key: k,
        label: m['label'] as String,
        shortName: m['short'] as String,
        payout: m['payout'] as int,
      ));
    });
    final myBets = <String, double>{};
    final myPayouts = <String, double>{};
    for (final b in (json['my_bets'] as List)) {
      final m = b as Map<String, dynamic>;
      myBets[m['bet_type'] as String] = (m['amount'] as num).toDouble();
      myPayouts[m['bet_type'] as String] = ((m['payout'] ?? 0) as num).toDouble();
    }
    final poolAmount = <String, double>{};
    final poolPlayers = <String, int>{};
    (json['pool'] as Map<String, dynamic>).forEach((k, v) {
      final m = v as Map<String, dynamic>;
      poolAmount[k] = (m['amount'] as num).toDouble();
      poolPlayers[k] = m['players'] as int;
    });
    final settled = phase == SicBoPhase.settled;
    return SicBoState(
      phase: phase,
      roundId: round['id'] as int?,
      secondsLeft: phase == SicBoPhase.open ? (round['seconds_left'] as num).toDouble() : 0,
      dice: settled ? (round['dice'] as List).map((e) => e as int).toList() : const [],
      total: settled ? round['total'] as int : 0,
      triple: settled ? round['triple'] as bool : false,
      secondsSinceSettled: settled ? (round['seconds_since_settled'] as num).toDouble() : 0,
      revealSecondsLeft: settled ? (round['reveal_seconds_left'] as num).toDouble() : 0,
      cash: (json['cash'] as num).toDouble(),
      betSeconds: json['bet_seconds'] as int,
      maxBetPerRound: json['max_bet_per_round'] as int,
      idleTimeoutSeconds: json['idle_timeout_seconds'] as int,
      mySeat: json['my_seat'] as int?,
      seats: (json['seats'] as List).map((e) => SicBoSeat.fromJson(e as Map<String, dynamic>)).toList(),
      betTypes: betTypes,
      myBets: myBets,
      myPayouts: myPayouts,
      poolAmount: poolAmount,
      poolPlayers: poolPlayers,
      history: (json['history'] as List).map((e) => SicBoHistoryItem.fromJson(e as Map<String, dynamic>)).toList(),
    );
  }
}

class SicBoBetResult {
  final bool ok;
  final String message;

  SicBoBetResult({required this.ok, required this.message});

  factory SicBoBetResult.fromJson(Map<String, dynamic> json) =>
      SicBoBetResult(ok: json['ok'] as bool, message: json['message'] as String);
}

// ===== 網頁版百家樂 =====

class PlayingCard {
  final int rank; // 1~13（1=A, 11=J, 12=Q, 13=K）
  final int suit; // 0=♠ 1=♥ 2=♦ 3=♣

  PlayingCard(this.rank, this.suit);

  factory PlayingCard.fromJson(dynamic json) {
    final l = json as List;
    return PlayingCard(l[0] as int, l[1] as int);
  }
}

class BaccaratBetType {
  final String key;
  final String shortName;
  final String payout; // 例如「1賠0.95」

  BaccaratBetType({required this.key, required this.shortName, required this.payout});
}

class BaccaratHistoryItem {
  final int id;
  final String result; // player / banker / tie
  final int playerTotal;
  final int bankerTotal;

  BaccaratHistoryItem({required this.id, required this.result, required this.playerTotal, required this.bankerTotal});

  factory BaccaratHistoryItem.fromJson(Map<String, dynamic> json) => BaccaratHistoryItem(
        id: json['id'] as int,
        result: json['result'] as String,
        playerTotal: json['player_total'] as int,
        bankerTotal: json['banker_total'] as int,
      );
}

class BaccaratState {
  final SicBoPhase phase; // 跟骰寶共用：idle / open / settled
  final int? roundId;
  final double secondsLeft;
  final List<PlayingCard> playerCards;
  final List<PlayingCard> bankerCards;
  final int playerTotal;
  final int bankerTotal;
  final String result;
  final bool playerPair;
  final bool bankerPair;
  final double secondsSinceSettled;
  final double revealSecondsLeft;
  final double cash;
  final int betSeconds;
  final int maxBetPerRound;
  final int idleTimeoutSeconds;
  final int? mySeat;
  final List<SicBoSeat> seats;
  final List<BaccaratBetType> betTypes;
  final Map<String, double> myBets;
  final Map<String, double> myPayouts;
  final Map<String, double> poolAmount;
  final Map<String, int> poolPlayers;
  final List<BaccaratHistoryItem> history;

  BaccaratState({
    required this.phase,
    required this.roundId,
    required this.secondsLeft,
    required this.playerCards,
    required this.bankerCards,
    required this.playerTotal,
    required this.bankerTotal,
    required this.result,
    required this.playerPair,
    required this.bankerPair,
    required this.secondsSinceSettled,
    required this.revealSecondsLeft,
    required this.cash,
    required this.betSeconds,
    required this.maxBetPerRound,
    required this.idleTimeoutSeconds,
    required this.mySeat,
    required this.seats,
    required this.betTypes,
    required this.myBets,
    required this.myPayouts,
    required this.poolAmount,
    required this.poolPlayers,
    required this.history,
  });

  bool get isIdle => phase == SicBoPhase.idle;
  bool get isOpen => phase == SicBoPhase.open;
  bool get isSettled => phase == SicBoPhase.settled;
  double get myTotalBet => myBets.values.fold(0.0, (a, b) => a + b);
  double get myTotalPayout => myPayouts.values.fold(0.0, (a, b) => a + b);

  factory BaccaratState.fromJson(Map<String, dynamic> json) {
    final round = json['round'] as Map<String, dynamic>;
    final phase = switch (round['status']) {
      'open' => SicBoPhase.open,
      'settled' => SicBoPhase.settled,
      _ => SicBoPhase.idle,
    };
    final settled = phase == SicBoPhase.settled;
    final betTypes = <BaccaratBetType>[];
    (json['bet_types'] as Map<String, dynamic>).forEach((k, v) {
      final m = v as Map<String, dynamic>;
      betTypes.add(BaccaratBetType(key: k, shortName: m['short'] as String, payout: m['payout'] as String));
    });
    final myBets = <String, double>{};
    final myPayouts = <String, double>{};
    for (final b in (json['my_bets'] as List)) {
      final m = b as Map<String, dynamic>;
      myBets[m['bet_type'] as String] = (m['amount'] as num).toDouble();
      myPayouts[m['bet_type'] as String] = ((m['payout'] ?? 0) as num).toDouble();
    }
    final poolAmount = <String, double>{};
    final poolPlayers = <String, int>{};
    (json['pool'] as Map<String, dynamic>).forEach((k, v) {
      final m = v as Map<String, dynamic>;
      poolAmount[k] = (m['amount'] as num).toDouble();
      poolPlayers[k] = m['players'] as int;
    });
    List<PlayingCard> cards(String key) =>
        settled ? (round[key] as List).map(PlayingCard.fromJson).toList() : const <PlayingCard>[];
    return BaccaratState(
      phase: phase,
      roundId: round['id'] as int?,
      secondsLeft: phase == SicBoPhase.open ? (round['seconds_left'] as num).toDouble() : 0,
      playerCards: cards('player_cards'),
      bankerCards: cards('banker_cards'),
      playerTotal: settled ? round['player_total'] as int : 0,
      bankerTotal: settled ? round['banker_total'] as int : 0,
      result: settled ? round['result'] as String : '',
      playerPair: settled ? round['player_pair'] as bool : false,
      bankerPair: settled ? round['banker_pair'] as bool : false,
      secondsSinceSettled: settled ? (round['seconds_since_settled'] as num).toDouble() : 0,
      revealSecondsLeft: settled ? (round['reveal_seconds_left'] as num).toDouble() : 0,
      cash: (json['cash'] as num).toDouble(),
      betSeconds: json['bet_seconds'] as int,
      maxBetPerRound: json['max_bet_per_round'] as int,
      idleTimeoutSeconds: json['idle_timeout_seconds'] as int,
      mySeat: json['my_seat'] as int?,
      seats: (json['seats'] as List).map((e) => SicBoSeat.fromJson(e as Map<String, dynamic>)).toList(),
      betTypes: betTypes,
      myBets: myBets,
      myPayouts: myPayouts,
      poolAmount: poolAmount,
      poolPlayers: poolPlayers,
      history: (json['history'] as List).map((e) => BaccaratHistoryItem.fromJson(e as Map<String, dynamic>)).toList(),
    );
  }
}

// ===== 網頁版賭馬 =====

class Horse {
  final int no;
  final String name;
  final Color color;
  final double winOdds;
  final double secondOdds;
  final double winProb;

  Horse({
    required this.no,
    required this.name,
    required this.color,
    required this.winOdds,
    required this.secondOdds,
    required this.winProb,
  });

  factory Horse.fromJson(Map<String, dynamic> json) {
    final hex = (json['color'] as String).replaceFirst('#', '');
    return Horse(
      no: json['no'] as int,
      name: json['name'] as String,
      color: Color(int.parse('FF$hex', radix: 16)),
      winOdds: (json['win_odds'] as num).toDouble(),
      secondOdds: (json['second_odds'] as num).toDouble(),
      winProb: (json['win_prob'] as num).toDouble(),
    );
  }
}

class HorseRace {
  final List<int> order; // 名次（馬號），第 0 個是冠軍
  final Map<int, double> finishTimes;
  final Map<int, List<double>> tracks; // 馬號 -> 每 trackStep 秒的前進比例（0~1）
  final double trackStep;
  final double raceSeconds;

  HorseRace({
    required this.order,
    required this.finishTimes,
    required this.tracks,
    required this.trackStep,
    required this.raceSeconds,
  });

  // 某一時刻（比賽開始後第 t 秒）某匹馬的前進比例，兩個關鍵點之間做線性內插。
  double progressAt(int no, double t) {
    final list = tracks[no];
    if (list == null || list.isEmpty) return 0;
    if (t <= 0) return 0;
    final x = t / trackStep;
    final i = x.floor();
    if (i >= list.length - 1) return list.last;
    return list[i] + (list[i + 1] - list[i]) * (x - i);
  }

  double get lastFinish => finishTimes.values.fold(0.0, (a, b) => a > b ? a : b);
}

class HorseHistoryItem {
  final int id;
  final int first;
  final int second;
  final String firstName;
  final String secondName;

  HorseHistoryItem({
    required this.id,
    required this.first,
    required this.second,
    required this.firstName,
    required this.secondName,
  });

  factory HorseHistoryItem.fromJson(Map<String, dynamic> json) => HorseHistoryItem(
        id: json['id'] as int,
        first: json['first'] as int,
        second: json['second'] as int,
        firstName: json['first_name'] as String,
        secondName: json['second_name'] as String,
      );
}

class HorseState {
  final SicBoPhase phase;
  final int? roundId;
  final double secondsLeft;
  final HorseRace? race;
  final double secondsSinceSettled;
  final double revealSecondsLeft;
  final List<Horse> horses;
  final List<SicBoSeat> seats;
  final int? mySeat;
  final Map<String, double> myBets; // key 例如 win:3
  final Map<String, double> myPayouts;
  final Map<String, double> poolAmount;
  final List<HorseHistoryItem> history;
  final double cash;
  final int betSeconds;
  final int maxBetPerRound;
  final int idleTimeoutSeconds;
  final double houseEdge;

  HorseState({
    required this.phase,
    required this.roundId,
    required this.secondsLeft,
    required this.race,
    required this.secondsSinceSettled,
    required this.revealSecondsLeft,
    required this.horses,
    required this.seats,
    required this.mySeat,
    required this.myBets,
    required this.myPayouts,
    required this.poolAmount,
    required this.history,
    required this.cash,
    required this.betSeconds,
    required this.maxBetPerRound,
    required this.idleTimeoutSeconds,
    required this.houseEdge,
  });

  bool get isIdle => phase == SicBoPhase.idle;
  bool get isOpen => phase == SicBoPhase.open;
  bool get isSettled => phase == SicBoPhase.settled;
  double get myTotalBet => myBets.values.fold(0.0, (a, b) => a + b);
  double get myTotalPayout => myPayouts.values.fold(0.0, (a, b) => a + b);

  Horse horse(int no) => horses.firstWhere((h) => h.no == no);

  factory HorseState.fromJson(Map<String, dynamic> json) {
    final round = json['round'] as Map<String, dynamic>;
    final phase = switch (round['status']) {
      'open' => SicBoPhase.open,
      'settled' => SicBoPhase.settled,
      _ => SicBoPhase.idle,
    };
    final settled = phase == SicBoPhase.settled;
    HorseRace? race;
    if (settled) {
      race = HorseRace(
        order: (round['order'] as List).map((e) => e as int).toList(),
        finishTimes: (round['finish_times'] as Map<String, dynamic>).map((k, v) => MapEntry(int.parse(k), (v as num).toDouble())),
        tracks: (round['tracks'] as Map<String, dynamic>).map(
          (k, v) => MapEntry(int.parse(k), (v as List).map((e) => (e as num).toDouble()).toList()),
        ),
        trackStep: (round['track_step'] as num).toDouble(),
        raceSeconds: (round['race_seconds'] as num).toDouble(),
      );
    }
    final myBets = <String, double>{};
    final myPayouts = <String, double>{};
    for (final b in (json['my_bets'] as List)) {
      final m = b as Map<String, dynamic>;
      myBets[m['bet_type'] as String] = (m['amount'] as num).toDouble();
      myPayouts[m['bet_type'] as String] = ((m['payout'] ?? 0) as num).toDouble();
    }
    final pool = <String, double>{};
    (json['pool'] as Map<String, dynamic>).forEach((k, v) {
      pool[k] = ((v as Map<String, dynamic>)['amount'] as num).toDouble();
    });
    return HorseState(
      phase: phase,
      roundId: round['id'] as int?,
      secondsLeft: phase == SicBoPhase.open ? (round['seconds_left'] as num).toDouble() : 0,
      race: race,
      secondsSinceSettled: settled ? (round['seconds_since_settled'] as num).toDouble() : 0,
      revealSecondsLeft: settled ? (round['reveal_seconds_left'] as num).toDouble() : 0,
      horses: (json['horses'] as List).map((e) => Horse.fromJson(e as Map<String, dynamic>)).toList(),
      seats: (json['seats'] as List).map((e) => SicBoSeat.fromJson(e as Map<String, dynamic>)).toList(),
      mySeat: json['my_seat'] as int?,
      myBets: myBets,
      myPayouts: myPayouts,
      poolAmount: pool,
      history: (json['history'] as List).map((e) => HorseHistoryItem.fromJson(e as Map<String, dynamic>)).toList(),
      cash: (json['cash'] as num).toDouble(),
      betSeconds: json['bet_seconds'] as int,
      maxBetPerRound: json['max_bet_per_round'] as int,
      idleTimeoutSeconds: json['idle_timeout_seconds'] as int,
      houseEdge: (json['house_edge'] as num).toDouble(),
    );
  }
}

// ===== 網頁版德州撲克 =====

// 後端的點數 A=14，這裡轉成跟百家樂共用的 PlayingCardFace 一樣的 A=1。
PlayingCard _pokerCard(dynamic json) {
  final l = json as List;
  final rank = l[0] as int;
  return PlayingCard(rank == 14 ? 1 : rank, l[1] as int);
}

class PokerSeat {
  final int seat;
  final String? userId;
  final String? name;
  final int stack;
  final bool isMe;
  final bool inHand;
  final String? status; // active / folded / allin
  final int betStreet;
  final List<PlayingCard>? cards; // 只有自己、或攤牌時還沒棄牌的人看得到
  final bool hasCards;
  final bool isDealer;
  final bool isToAct;
  final int? net;
  final String? handName;

  PokerSeat({
    required this.seat,
    required this.userId,
    required this.name,
    required this.stack,
    required this.isMe,
    required this.inHand,
    required this.status,
    required this.betStreet,
    required this.cards,
    required this.hasCards,
    required this.isDealer,
    required this.isToAct,
    required this.net,
    required this.handName,
  });

  bool get occupied => userId != null;

  factory PokerSeat.fromJson(Map<String, dynamic> j) => PokerSeat(
        seat: j['seat'] as int,
        userId: j['user_id'] as String?,
        name: j['name'] as String?,
        stack: (j['stack'] as num).toInt(),
        isMe: j['is_me'] as bool,
        inHand: j['in_hand'] as bool,
        status: j['status'] as String?,
        betStreet: (j['bet_street'] as num).toInt(),
        cards: j['cards'] == null ? null : (j['cards'] as List).map(_pokerCard).toList(),
        hasCards: j['has_cards'] as bool,
        isDealer: j['is_dealer'] as bool,
        isToAct: j['is_to_act'] as bool,
        net: (j['net'] as num?)?.toInt(),
        handName: j['hand_name'] as String?,
      );
}

class PokerPotResult {
  final int amount;
  final List<String> winners;
  PokerPotResult({required this.amount, required this.winners});
}

class PokerHand {
  final int id;
  final bool finished;
  final int street; // 0 翻牌前 1 翻牌 2 轉牌 3 河牌
  final List<PlayingCard> board;
  final int pot;
  final int currentBet;
  final int? toActSeat;
  final double? secondsLeft;
  final bool showdown;
  final List<PokerPotResult> pots;

  PokerHand({
    required this.id,
    required this.finished,
    required this.street,
    required this.board,
    required this.pot,
    required this.currentBet,
    required this.toActSeat,
    required this.secondsLeft,
    required this.showdown,
    required this.pots,
  });

  factory PokerHand.fromJson(Map<String, dynamic> j) {
    final result = j['result'] as Map<String, dynamic>?;
    return PokerHand(
      id: j['id'] as int,
      finished: j['status'] == 'finished',
      street: j['street'] as int,
      board: (j['board'] as List).map(_pokerCard).toList(),
      pot: (j['pot'] as num).toInt(),
      currentBet: (j['current_bet'] as num).toInt(),
      toActSeat: j['to_act_seat'] as int?,
      secondsLeft: (j['seconds_left'] as num?)?.toDouble(),
      showdown: result?['showdown'] == true,
      pots: result == null
          ? const []
          : (result['pots'] as List)
              .map((p) => PokerPotResult(
                    amount: (p['amount'] as num).toInt(),
                    winners: (p['winners'] as List).map((w) => (w as Map<String, dynamic>)['name'] as String).toList(),
                  ))
              .toList(),
    );
  }
}

class PokerActions {
  final bool canAct;
  final bool canCheck;
  final int callAmount;
  final bool canRaise;
  final int minRaiseTo;
  final int maxRaiseTo;

  PokerActions({
    required this.canAct,
    required this.canCheck,
    required this.callAmount,
    required this.canRaise,
    required this.minRaiseTo,
    required this.maxRaiseTo,
  });

  factory PokerActions.fromJson(Map<String, dynamic> j) => PokerActions(
        canAct: j['can_act'] as bool,
        canCheck: (j['can_check'] as bool?) ?? false,
        callAmount: ((j['call_amount'] as num?) ?? 0).toInt(),
        canRaise: (j['can_raise'] as bool?) ?? false,
        minRaiseTo: ((j['min_raise_to'] as num?) ?? 0).toInt(),
        maxRaiseTo: ((j['max_raise_to'] as num?) ?? 0).toInt(),
      );
}

class PokerHistoryItem {
  final int id;
  final int pot;
  final String winner;
  final int winnerNet;
  final String? hand;

  PokerHistoryItem({required this.id, required this.pot, required this.winner, required this.winnerNet, required this.hand});

  factory PokerHistoryItem.fromJson(Map<String, dynamic> j) => PokerHistoryItem(
        id: j['id'] as int,
        pot: (j['pot'] as num).toInt(),
        winner: j['winner'] as String,
        winnerNet: (j['winner_net'] as num).toInt(),
        hand: j['hand'] as String?,
      );
}

class PokerState {
  final double cash;
  final int? mySeat;
  final List<PokerSeat> seats;
  final PokerHand? hand;
  final PokerActions actions;
  final List<PokerHistoryItem> history;
  final int smallBlind;
  final int bigBlind;
  final int minBuyin;
  final int maxBuyin;
  final int actionSeconds;

  PokerState({
    required this.cash,
    required this.mySeat,
    required this.seats,
    required this.hand,
    required this.actions,
    required this.history,
    required this.smallBlind,
    required this.bigBlind,
    required this.minBuyin,
    required this.maxBuyin,
    required this.actionSeconds,
  });

  factory PokerState.fromJson(Map<String, dynamic> j) {
    final t = j['table'] as Map<String, dynamic>;
    return PokerState(
      cash: (j['cash'] as num).toDouble(),
      mySeat: j['my_seat'] as int?,
      seats: (j['seats'] as List).map((e) => PokerSeat.fromJson(e as Map<String, dynamic>)).toList(),
      hand: j['hand'] == null ? null : PokerHand.fromJson(j['hand'] as Map<String, dynamic>),
      actions: PokerActions.fromJson(j['my_actions'] as Map<String, dynamic>),
      history: (j['history'] as List).map((e) => PokerHistoryItem.fromJson(e as Map<String, dynamic>)).toList(),
      smallBlind: (t['small_blind'] as num).toInt(),
      bigBlind: (t['big_blind'] as num).toInt(),
      minBuyin: (t['min_buyin'] as num).toInt(),
      maxBuyin: (t['max_buyin'] as num).toInt(),
      actionSeconds: (t['action_seconds'] as num).toInt(),
    );
  }
}


class BookLevel {
  final double price;
  final int lots;

  BookLevel({required this.price, required this.lots});

  factory BookLevel.fromJson(Map<String, dynamic> json) =>
      BookLevel(price: (json['price'] as num).toDouble(), lots: (json['lots'] as num).toInt());
}

class OrderBook {
  final double basePrice;
  final double mid;
  final List<BookLevel> asks; // 賣盤，由近到遠（賣一在前）
  final List<BookLevel> bids; // 買盤，由近到遠（買一在前）

  OrderBook({required this.basePrice, required this.mid, required this.asks, required this.bids});

  factory OrderBook.fromJson(Map<String, dynamic> json) {
    List<BookLevel> levels(String key) => (json[key] as List)
        .map((e) => BookLevel.fromJson(e as Map<String, dynamic>))
        .toList();
    return OrderBook(
      basePrice: (json['base_price'] as num).toDouble(),
      mid: (json['mid'] as num).toDouble(),
      asks: levels('asks'),
      bids: levels('bids'),
    );
  }
}

class TradeQuote {
  final double avgPrice;
  final double mid;
  final double slippagePct;

  TradeQuote({required this.avgPrice, required this.mid, required this.slippagePct});

  factory TradeQuote.fromJson(Map<String, dynamic> json) => TradeQuote(
        avgPrice: (json['avg_price'] as num).toDouble(),
        mid: (json['mid'] as num).toDouble(),
        slippagePct: (json['slippage_pct'] as num).toDouble(),
      );
}


class Candle {
  final DateTime time;
  final double open;
  final double high;
  final double low;
  final double close;

  Candle({required this.time, required this.open, required this.high, required this.low, required this.close});

  factory Candle.fromJson(Map<String, dynamic> json) => Candle(
        time: DateTime.parse(json['time'] as String),
        open: (json['open'] as num).toDouble(),
        high: (json['high'] as num).toDouble(),
        low: (json['low'] as num).toDouble(),
        close: (json['close'] as num).toDouble(),
      );
}
