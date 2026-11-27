import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../../models/model.dart';
import '../../models/platform_model.dart';

/// Touch-screen mode: every finger on the remote image is sent to the
/// controlled Windows PC as a native touch contact, so the PC behaves as if
/// the tablet were its touch screen (one-finger swipe scrolls, press and
/// hold is right click, pinch zooms inside apps, ...).
class NativeTouchRegion extends StatefulWidget {
  final Widget child;
  final FFI ffi;

  const NativeTouchRegion({super.key, required this.child, required this.ffi});

  @override
  State<NativeTouchRegion> createState() => _NativeTouchRegionState();
}

class _NativeTouchRegionState extends State<NativeTouchRegion> {
  static const int _maxContacts = 10;
  static const int _stateDown = 0;
  static const int _stateMove = 1;
  static const int _stateUp = 2;
  static const int _stateCancel = 3;
  // The controlled side lifts all contacts if it hears nothing for 2 s,
  // so held fingers are re-sent while they are down.
  static const Duration _heartbeat = Duration(milliseconds: 500);

  // Flutter pointer -> contact id (0..9)
  final Map<int, int> _ids = {};
  // contact id -> last remote position
  final Map<int, Offset> _pos = {};
  Timer? _timer;

  FFI get ffi => widget.ffi;

  @override
  void dispose() {
    _timer?.cancel();
    if (_pos.isNotEmpty) {
      _send({for (final id in _pos.keys) id: _stateCancel});
      _pos.clear();
      _ids.clear();
    }
    super.dispose();
  }

  bool _accept(PointerEvent e) =>
      e.kind == PointerDeviceKind.touch || e.kind == PointerDeviceKind.stylus;

  bool _blocked(Offset local) {
    final rect = ffi.cursorModel.keyHelpToolsRectToAdjustCanvas;
    return rect != null && rect.contains(local);
  }

  int? _freeId() {
    for (var i = 0; i < _maxContacts; i++) {
      if (!_pos.containsKey(i)) return i;
    }
    return null;
  }

  void _onDown(PointerDownEvent e) {
    if (!_accept(e) || _blocked(e.localPosition)) return;
    final id = _freeId();
    if (id == null) return;
    final pos = ffi.cursorModel.remotePosForTouch(e.localPosition);
    if (pos == null) return;
    _ids[e.pointer] = id;
    _pos[id] = pos;
    _send({id: _stateDown});
    _timer ??= Timer.periodic(_heartbeat, (_) => _send({}));
  }

  void _onMove(PointerMoveEvent e) {
    final id = _ids[e.pointer];
    if (id == null) return;
    final pos = ffi.cursorModel.remotePosForTouch(e.localPosition, clamp: true);
    if (pos == null) return;
    final last = _pos[id];
    if (last != null &&
        last.dx.round() == pos.dx.round() &&
        last.dy.round() == pos.dy.round()) {
      return;
    }
    _pos[id] = pos;
    _send({id: _stateMove});
  }

  void _onEnd(PointerEvent e, int state) {
    final id = _ids.remove(e.pointer);
    if (id == null) return;
    _send({id: state});
    _pos.remove(id);
    if (_pos.isEmpty) {
      _timer?.cancel();
      _timer = null;
    }
  }

  /// Sends one frame: every contact currently down, with [changed] giving
  /// the state of the contacts that changed in this frame.
  void _send(Map<int, int> changed) {
    if (_pos.isEmpty) return;
    final contacts = <Map<String, int>>[];
    _pos.forEach((id, p) {
      contacts.add({
        'i': id,
        'x': p.dx.round(),
        'y': p.dy.round(),
        's': changed[id] ?? _stateMove,
      });
    });
    final msg = {
      'k': 'touch',
      'v': {'t': 'contacts', 'v': contacts},
    };
    bind.sessionSendPointer(sessionId: ffi.sessionId, msg: json.encode(msg));
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _onDown,
      onPointerMove: _onMove,
      onPointerUp: (e) => _onEnd(e, _stateUp),
      onPointerCancel: (e) => _onEnd(e, _stateCancel),
      child: widget.child,
    );
  }
}
