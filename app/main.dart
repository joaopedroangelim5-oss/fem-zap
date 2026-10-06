import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:image_picker/image_picker.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

const sid = 'com.femzap.app';
late SharedPreferences sp;
final nb = Nearby();
final st = S();
final walls = [
  [0xFF0B0B1A, 0xFF1B1F5E], [0xFF0F2027, 0xFF2C5364], [0xFF200122, 0xFF6f0000],
  [0xFF134E5E, 0xFF71B280], [0xFF232526, 0xFF414345], [0xFF1D2B64, 0xFFF8CDDA],
];

class S extends ChangeNotifier {
  String id = '', name = '', photo = '';
  Map con = {};
  Map<String, List> msgs = {};
  final ep = <String, String>{}, eps = <String, String>{}, names = <String, String>{};
  final found = <String, String>{}, paths = <int, String>{}, done = <int>{};
  final pend = <String, ConnectionInfo>{};
  final metas = <int, Map>{};

  void load() {
    final d = jsonDecode(sp.getString('d') ?? '{}');
    id = d['id'] ?? (Random().nextInt(1 << 31).toRadixString(36) + DateTime.now().millisecondsSinceEpoch.toRadixString(36));
    name = d['n'] ?? '';
    photo = d['p'] ?? '';
    con = d['c'] ?? {};
    (d['m'] ?? {}).forEach((k, v) => msgs[k] = List.from(v));
    save();
  }

  void save() {
    sp.setString('d', jsonEncode({'id': id, 'n': name, 'p': photo, 'c': con, 'm': msgs}));
    notifyListeners();
  }

  String get un => '${name.replaceAll('|', '/')}|$id';

  Future<void> start() async {
    try {
      await [Permission.location, Permission.bluetoothScan, Permission.bluetoothAdvertise, Permission.bluetoothConnect, Permission.nearbyWifiDevices].request();
    } catch (_) {}
    try {
      await nb.startAdvertising(un, Strategy.P2P_CLUSTER,
          onConnectionInitiated: _init, onConnectionResult: _res, onDisconnected: _disc, serviceId: sid);
    } catch (_) {}
    try {
      await nb.startDiscovery(un, Strategy.P2P_CLUSTER, onEndpointFound: (e, n, s) {
        found[e] = n;
        final cid = n.split('|').last;
        if (con.containsKey(cid) && !ep.containsKey(cid) && id.compareTo(cid) > 0) req(e);
        notifyListeners();
      }, onEndpointLost: (e) {
        found.remove(e);
        notifyListeners();
      }, serviceId: sid);
    } catch (_) {}
  }

  void req(String e) => nb.requestConnection(un, e,
      onConnectionInitiated: _init, onConnectionResult: _res, onDisconnected: _disc).catchError((_) => false);

  void _init(String e, ConnectionInfo i) {
    names[e] = i.endpointName;
    if (con.containsKey(i.endpointName.split('|').last)) {
      acc(e);
    } else {
      pend[e] = i;
      notifyListeners();
    }
  }

  void acc(String e) {
    pend.remove(e);
    nb.acceptConnection(e, onPayLoadRecieved: _pay, onPayloadTransferUpdate: _upd);
    notifyListeners();
  }

  void rej(String e) {
    pend.remove(e);
    nb.rejectConnection(e);
    notifyListeners();
  }

  void _res(String e, Status s) {
    if (s != Status.CONNECTED) return;
    final p = (names[e] ?? '|').split('|');
    final cid = p.last;
    ep[cid] = e;
    eps[e] = cid;
    con.putIfAbsent(cid, () => {'name': p.first, 'photo': '', 'wall': 'g0', 'pin': false, 'mute': false});
    if (photo.isNotEmpty) _sendFile(e, photo, {'k': 'photo'});
    for (final m in msgs[cid] ?? []) {
      if (m['me'] == true && m['st'] == 0) _push(cid, m);
    }
    save();
  }

  void _disc(String e) {
    final cid = eps.remove(e);
    if (cid != null) ep.remove(cid);
    notifyListeners();
  }

  void _b(String e, Map j) => nb.sendBytesPayload(e, Uint8List.fromList(utf8.encode(jsonEncode(j))));

  Future<void> _sendFile(String e, String path, Map meta) async {
    final pid = await nb.sendFilePayload(e, path);
    _b(e, {...meta, 't': 'file', 'pid': pid, 'n': path.split('/').last});
  }

  Future<void> send(String cid, String k, String t) async {
    if (k != 'text') {
      final d = await getApplicationDocumentsDirectory();
      t = (await File(t).copy('${d.path}/${DateTime.now().microsecondsSinceEpoch}_${t.split('/').last}')).path;
    }
    final m = {'me': true, 'k': k, 't': t, 'ts': DateTime.now().millisecondsSinceEpoch,
      'mid': '${DateTime.now().microsecondsSinceEpoch}${Random().nextInt(99)}', 'st': 0};
    (msgs[cid] ??= []).add(m);
    save();
    _push(cid, m);
  }

  void _push(String cid, Map m) {
    final e = ep[cid];
    if (e == null) return;
    if (m['k'] == 'text') {
      _b(e, {'t': 'msg', 'mid': m['mid'], 'x': m['t']});
    } else {
      _sendFile(e, m['t'], {'k': m['k'], 'mid': m['mid']});
    }
  }

  void _pay(String e, Payload p) {
    final cid = eps[e];
    if (cid == null) return;
    if (p.type == PayloadType.BYTES) {
      final j = jsonDecode(utf8.decode(p.bytes!));
      if (j['t'] == 'msg') {
        (msgs[cid] ??= []).add({'me': false, 'k': 'text', 't': j['x'], 'ts': DateTime.now().millisecondsSinceEpoch, 'mid': j['mid'], 'st': 1});
        _b(e, {'t': 'ack', 'mid': j['mid']});
        save();
      } else if (j['t'] == 'ack') {
        for (final m in msgs[cid] ?? []) {
          if (m['mid'] == j['mid']) m['st'] = 1;
        }
        save();
      } else if (j['t'] == 'file') {
        metas[j['pid']] = j;
        _try(e, j['pid']);
      }
    } else if (p.type == PayloadType.FILE) {
      paths[p.id] = p.filePath!;
      _try(e, p.id);
    }
  }

  void _upd(String e, PayloadTransferUpdate u) {
    if (u.status == PayloadStatus.SUCCESS) {
      done.add(u.id);
      _try(e, u.id);
    }
  }

  Future<void> _try(String e, int pid) async {
    final j = metas[pid], src = paths[pid], cid = eps[e];
    if (j == null || src == null || cid == null || !done.contains(pid)) return;
    metas.remove(pid);
    final d = await getApplicationDocumentsDirectory();
    final dest = (await File(src).copy('${d.path}/${DateTime.now().microsecondsSinceEpoch}_${j['n']}')).path;
    if (j['k'] == 'photo') {
      con[cid]['photo'] = dest;
    } else {
      (msgs[cid] ??= []).add({'me': false, 'k': j['k'], 't': dest, 'ts': DateTime.now().millisecondsSinceEpoch, 'mid': j['mid'], 'st': 1});
      _b(e, {'t': 'ack', 'mid': j['mid']});
    }
    save();
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  sp = await SharedPreferences.getInstance();
  st.load();
  if (st.name.isNotEmpty) st.start();
  runApp(const FemZap());
}

class FemZap extends StatelessWidget {
  const FemZap({super.key});
  @override
  Widget build(BuildContext c) => MaterialApp(
        title: 'Fem-Zap',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: const Color(0xFF3B4BFF), useMaterial3: true),
        darkTheme: ThemeData(colorSchemeSeed: const Color(0xFF3B4BFF), brightness: Brightness.dark, useMaterial3: true),
        home: ListenableBuilder(listenable: st, builder: (c, _) => st.name.isEmpty ? const Setup() : const Home()),
      );
}

Widget av(String photo, String name, [double r = 22]) => CircleAvatar(
      radius: r,
      backgroundImage: photo.isNotEmpty ? FileImage(File(photo)) : null,
      child: photo.isEmpty ? Text(name.isEmpty ? '?' : name[0].toUpperCase()) : null,
    );

class Setup extends StatefulWidget {
  const Setup({super.key});
  @override
  State<Setup> createState() => _Setup();
}

class _Setup extends State<Setup> {
  late final c = TextEditingController(text: st.name);
  String photo = st.photo;
  @override
  Widget build(BuildContext ctx) => Scaffold(
        appBar: AppBar(title: const Text('Seu perfil')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(children: [
            GestureDetector(
              onTap: () async {
                final f = await ImagePicker().pickImage(source: ImageSource.gallery);
                if (f != null) {
                  final d = await getApplicationDocumentsDirectory();
                  photo = (await File(f.path).copy('${d.path}/perfil_${DateTime.now().millisecondsSinceEpoch}.jpg')).path;
                  setState(() {});
                }
              },
              child: av(photo, c.text, 60),
            ),
            const SizedBox(height: 8),
            const Text('Toque para escolher a foto'),
            const SizedBox(height: 24),
            TextField(controller: c, decoration: const InputDecoration(labelText: 'Seu nome', border: OutlineInputBorder())),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () {
                if (c.text.trim().isEmpty) return;
                final first = st.name.isEmpty;
                st.name = c.text.trim();
                st.photo = photo;
                st.save();
                if (first) st.start();
                if (Navigator.canPop(ctx)) Navigator.pop(ctx);
              },
              child: const Text('Salvar'),
            ),
          ]),
        ),
      );
}

Widget pendTiles() => Column(children: [
      for (final e in st.pend.entries)
        Card(
          child: ListTile(
            title: Text('${e.value.endpointName.split('|').first} quer conversar'),
            subtitle: Text('Código: ${e.value.authenticationToken}'),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(icon: const Icon(Icons.close), onPressed: () => st.rej(e.key)),
              IconButton(icon: const Icon(Icons.check), onPressed: () => st.acc(e.key)),
            ]),
          ),
        ),
    ]);

class Home extends StatelessWidget {
  const Home({super.key});
  @override
  Widget build(BuildContext c) {
    final ids = st.con.keys.cast<String>().toList()
      ..sort((a, b) => (st.con[b]['pin'] == true ? 1 : 0) - (st.con[a]['pin'] == true ? 1 : 0));
    return Scaffold(
      appBar: AppBar(
        title: Row(children: [Image.asset('assets/logo.png', width: 32), const SizedBox(width: 8), const Text('Fem-Zap')]),
        actions: [
          IconButton(icon: const Icon(Icons.person), onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const Setup()))),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.bluetooth_searching),
        label: const Text('Buscar contatos'),
        onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const Nearby0())),
      ),
      body: ListView(children: [
        pendTiles(),
        if (ids.isEmpty)
          const Padding(padding: EdgeInsets.all(32), child: Text('Nenhum contato ainda. Toque em "Buscar contatos" com o outro aparelho por perto.', textAlign: TextAlign.center)),
        for (final id in ids)
          ListTile(
            leading: av(st.con[id]['photo'], st.con[id]['name']),
            title: Text(st.con[id]['name']),
            subtitle: Text(_last(id), maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              if (st.con[id]['pin'] == true) const Icon(Icons.push_pin, size: 16),
              if (st.con[id]['mute'] == true) const Icon(Icons.volume_off, size: 16),
              if (st.ep.containsKey(id)) const Icon(Icons.circle, size: 12, color: Colors.green),
            ]),
            onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => Chat(id))),
          ),
      ]),
    );
  }

  String _last(String id) {
    final l = st.msgs[id];
    if (l == null || l.isEmpty) return 'Toque para conversar';
    final m = l.last;
    return m['k'] == 'text' ? m['t'] : '📎 ${m['k']}';
  }
}

class Nearby0 extends StatelessWidget {
  const Nearby0({super.key});
  @override
  Widget build(BuildContext c) => Scaffold(
        appBar: AppBar(title: const Text('Aparelhos por perto')),
        body: ListenableBuilder(
          listenable: st,
          builder: (c, _) => ListView(children: [
            pendTiles(),
            for (final e in st.found.entries)
              if (!st.eps.containsKey(e.key))
                ListTile(
                  leading: av('', e.value.split('|').first),
                  title: Text(e.value.split('|').first),
                  subtitle: const Text('Toque para conectar e salvar contato'),
                  onTap: () => st.req(e.key),
                ),
            if (st.found.isEmpty)
              const Padding(padding: EdgeInsets.all(32), child: Text('Procurando... peça para o outro abrir o Fem-Zap.', textAlign: TextAlign.center)),
          ]),
        ),
      );
}

class Chat extends StatefulWidget {
  final String cid;
  const Chat(this.cid, {super.key});
  @override
  State<Chat> createState() => _Chat();
}

class _Chat extends State<Chat> {
  final c = TextEditingController();
  String get cid => widget.cid;
  Map get ct => st.con[cid];

  Future<void> pick(String k) async {
    final p = ImagePicker();
    final f = k == 'video' ? await p.pickVideo(source: ImageSource.gallery) : await p.pickImage(source: ImageSource.gallery);
    if (f != null) st.send(cid, k, f.path);
  }

  Future<void> dl(Map m) async {
    try {
      await Gal.requestAccess();
      m['k'] == 'video' ? await Gal.putVideo(m['t']) : await Gal.putImage(m['t']);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Salvo na galeria')));
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Não foi possível salvar')));
    }
  }

  BoxDecoration wall() {
    final w = '${ct['wall']}';
    if (w.startsWith('/')) return BoxDecoration(image: DecorationImage(image: FileImage(File(w)), fit: BoxFit.cover));
    final g = walls[int.tryParse(w.replaceAll('g', '')) ?? 0];
    return BoxDecoration(gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(g[0]), Color(g[1])]));
  }

  void pickWall() => showModalBottomSheet(
        context: context,
        builder: (_) => Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(spacing: 12, runSpacing: 12, children: [
            for (var i = 0; i < walls.length; i++)
              GestureDetector(
                onTap: () {
                  ct['wall'] = 'g$i';
                  st.save();
                  Navigator.pop(context);
                },
                child: CircleAvatar(radius: 24, backgroundColor: Color(walls[i][1])),
              ),
            ActionChip(
              avatar: const Icon(Icons.image),
              label: const Text('Foto da galeria'),
              onPressed: () async {
                final f = await ImagePicker().pickImage(source: ImageSource.gallery);
                if (f != null) {
                  final d = await getApplicationDocumentsDirectory();
                  ct['wall'] = (await File(f.path).copy('${d.path}/wall_${DateTime.now().millisecondsSinceEpoch}.jpg')).path;
                  st.save();
                }
                if (mounted) Navigator.pop(context);
              },
            ),
          ]),
        ),
      );

  Widget bubble(Map m) {
    final me = m['me'] == true;
    final k = m['k'];
    Widget body;
    if (k == 'text') {
      body = Text(m['t'], style: const TextStyle(color: Colors.white, fontSize: 16));
    } else if (k == 'image' || k == 'gif' || k == 'sticker') {
      body = GestureDetector(
        onTap: () => showDialog(context: context, builder: (_) => Dialog(child: InteractiveViewer(child: Image.file(File(m['t']))))),
        child: Image.file(File(m['t']), width: k == 'sticker' ? 130 : 220),
      );
    } else {
      body = Row(mainAxisSize: MainAxisSize.min, children: const [
        Icon(Icons.videocam, color: Colors.white), SizedBox(width: 6), Text('Vídeo', style: TextStyle(color: Colors.white)),
      ]);
    }
    final canDl = k == 'image' || k == 'gif' || k == 'sticker' || k == 'video';
    final inner = Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
      body,
      Row(mainAxisSize: MainAxisSize.min, children: [
        if (canDl)
          InkWell(onTap: () => dl(m), child: const Padding(padding: EdgeInsets.all(2), child: Icon(Icons.download, size: 16, color: Colors.white70))),
        if (me) Icon(m['st'] == 1 ? Icons.done_all : Icons.done, size: 14, color: m['st'] == 1 ? Colors.lightBlueAccent : Colors.white70),
      ]),
    ]);
    return Align(
      alignment: me ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3, horizontal: 10),
        padding: const EdgeInsets.all(8),
        constraints: const BoxConstraints(maxWidth: 280),
        decoration: k == 'sticker' ? null : BoxDecoration(color: me ? const Color(0xFF2B3BE0) : const Color(0xFF2A3050), borderRadius: BorderRadius.circular(14)),
        child: inner,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: st,
        builder: (context, _) {
          final l = st.msgs[cid] ?? [];
          return Scaffold(
            appBar: AppBar(
              leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.pop(context)),
              title: Row(children: [
                av(ct['photo'], ct['name'], 18), const SizedBox(width: 10),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(ct['name'], style: const TextStyle(fontSize: 16)),
                  Text(st.ep.containsKey(cid) ? 'conectado' : 'fora de alcance', style: const TextStyle(fontSize: 12)),
                ]),
              ]),
              actions: [
                PopupMenuButton<String>(
                  onSelected: (v) {
                    if (v == 'w') pickWall();
                    if (v == 'p') ct['pin'] = ct['pin'] != true;
                    if (v == 'm') ct['mute'] = ct['mute'] != true;
                    st.save();
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'w', child: Text('Papel de parede')),
                    PopupMenuItem(value: 'p', child: Text(ct['pin'] == true ? 'Desafixar' : 'Fixar')),
                    PopupMenuItem(value: 'm', child: Text(ct['mute'] == true ? 'Reativar som' : 'Silenciar')),
                  ],
                ),
              ],
            ),
            body: Container(
              decoration: wall(),
              child: Column(children: [
                Expanded(child: ListView.builder(reverse: true, itemCount: l.length, itemBuilder: (_, i) => bubble(l[l.length - 1 - i]))),
                SafeArea(
                  child: Row(children: [
                    PopupMenuButton<String>(
                      icon: const Icon(Icons.attach_file),
                      onSelected: pick,
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'image', child: Text('Foto')),
                        PopupMenuItem(value: 'video', child: Text('Vídeo')),
                        PopupMenuItem(value: 'sticker', child: Text('Figurinha')),
                        PopupMenuItem(value: 'gif', child: Text('GIF')),
                      ],
                    ),
                    Expanded(child: TextField(controller: c, decoration: const InputDecoration(hintText: 'Mensagem', filled: true, border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(24)), borderSide: BorderSide.none)))),
                    IconButton(
                      icon: const Icon(Icons.send),
                      onPressed: () {
                        if (c.text.trim().isEmpty) return;
                        st.send(cid, 'text', c.text.trim());
                        c.clear();
                      },
                    ),
                  ]),
                ),
              ]),
            ),
          );
        },
      );
}
