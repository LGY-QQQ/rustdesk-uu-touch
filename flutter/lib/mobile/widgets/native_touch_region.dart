import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../../models/input_model.dart';
import '../../models/model.dart';
import '../../models/platform_model.dart';

/// Touch-screen mode: every finger on the remote image is sent to the
/// controlled Windows PC as a native touch contact, so the PC behaves as if
/// the tablet were its touch screen (one-finger swipe scrolls, pinch zooms
/// inside apps, ...).
///
/// Two additions on top of plain touch:
/// * Press and hold one finger, then drag: the touch is cancelled and the
///   drag becomes a left-button mouse drag, so text is selected the way a
///   mouse selects it (apps that react to mouse selection, such as a
///   "quote" button, work). Press and hold and lift without dragging is a
///   right click.
/// * A second tap close to the first one is sent at exactly the first tap's
///   position, so finger jitter does not break Windows' double tap.
class NativeTouchRegion extends StatefulWidget {
  final Widget child;
  final FFI ffi;

  const NativeTouchRegion({super.key, required this.child, required this.ffi});

  @override
  State<NativeTouchRegion> createState() => _NativeTouchRegionState();
}

class _Contact {
  final int id;
  final Offset downLocal;
  final DateTime downTime;
  // Remote position the contact is pinned to while it stays within the
  // slop (double-tap snapping).
  Offset? anchor;
  bool moved = false;
  bool hadCompany = false;

  _Contact(this.id, this.downLocal, this.downTime);
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
  // Shorter than Chromium's touch long press (500 ms) so the touch is
  // cancelled before the app starts its own touch selection.
  static const Duration _holdDelay = Duration(milliseconds: 400);
  // Local (tablet) logical pixels.
  static const double _slop = 10;
  static const double _dragSlop = 6;
  static const Duration _tapMaxDuration = Duration(milliseconds: 300);
  static const Duration _doubleTapWindow = Duration(milliseconds: 500);
  static const double _doubleTapDistance = 30;

  // Flutter pointer -> contact
  final Map<int, _Contact> _contacts = {};
  // contact id -> last remote position sent
  final Map<int, Offset> _pos = {};
  Timer? _timer;

  // Press-and-hold -> mouse
  Timer? _holdTimer;
  int? _holdPointer;
  int? _mousePointer;
  Offset _mouseStartLocal = Offset.zero;
  Offset? _mouseLast;
  bool _mouseDragging = false;

  // Last single tap, for double-tap snapping.
  DateTime? _lastTapUp;
  Offset _lastTapLocal = Offset.zero;
  Offset _lastTapRemote = Offset.zero;

  FFI get ffi => widget.ffi;
  InputModel get input => ffi.inputModel;

  @override
  void dispose() {
    _timer?.cancel();
    _cancelHold();
    if (_mousePointer != null && _mouseDragging) {
      input.sendMouse('up', MouseButtons.left);
    }
    _mousePointer = null;
    ffi.cursorModel.touchFocus = null;
    if (_pos.isNotEmpty) {
      _send({for (final id in _pos.keys) id: _stateCancel});
      _pos.clear();
      _contacts.clear();
    }
    super.dispose();
  }

  bool _accept(PointerEvent e) =>
      e.kind == PointerDeviceKind.touch || e.kind == PointerDeviceKind.stylus;

  // [global]: pointer position on the screen. Touches on the key help bar
  // and on its toggle button stay on the tablet.
  bool _blocked(Offset global) {
    final bar = ffi.cursorModel.keyHelpToolsRect;
    if (bar != null && bar.contains(global)) return true;
    final button = ffi.cursorModel.keyBarButtonRect;
    return button != null && button.inflate(6).contains(global);
  }

  int? _freeId() {
    for (var i = 0; i < _maxContacts; i++) {
      if (!_pos.containsKey(i)) return i;
    }
    return null;
  }

  void _cancelHold() {
    _holdTimer?.cancel();
    _holdTimer = null;
    _holdPointer = null;
  }

  void _onDown(PointerDownEvent e) {
    // While a held finger drives the mouse, other fingers are ignored.
    if (_mousePointer != null) return;
    if (!_accept(e) || _blocked(e.position)) return;
    final id = _freeId();
    if (id == null) return;
    var pos = ffi.cursorModel.remotePosForTouch(e.localPosition);
    if (pos == null) return;
    final now = DateTime.now();
    final c = _Contact(id, e.localPosition, now);
    final lone = _contacts.isEmpty;
    if (lone &&
        _lastTapUp != null &&
        now.difference(_lastTapUp!) <= _doubleTapWindow &&
        (e.localPosition - _lastTapLocal).distance <= _doubleTapDistance) {
      c.anchor = _lastTapRemote;
      pos = _lastTapRemote;
    }
    if (!lone) {
      c.hadCompany = true;
      for (final other in _contacts.values) {
        other.hadCompany = true;
      }
      _cancelHold();
    }
    _contacts[e.pointer] = c;
    _pos[id] = pos;
    _send({id: _stateDown});
    _timer ??= Timer.periodic(_heartbeat, (_) => _send({}));
    if (lone) {
      _holdPointer = e.pointer;
      _holdTimer = Timer(_holdDelay, () => _onHold(e.pointer));
    }
  }

  void _onHold(int pointer) {
    _holdTimer = null;
    if (_holdPointer != pointer) return;
    _holdPointer = null;
    final c = _contacts[pointer];
    if (c == null || c.moved || c.hadCompany || _contacts.length != 1) return;
    final start = _pos[c.id];
    if (start == null) return;
    // Take the finger off the touch screen and continue with the mouse.
    _send({c.id: _stateCancel});
    _contacts.remove(pointer);
    _pos.remove(c.id);
    _stopHeartbeatIfIdle();
    _mousePointer = pointer;
    _mouseStartLocal = c.downLocal;
    _mouseDragging = false;
    _mouseLast = start;
    input.moveMouse(start.dx, start.dy);
  }

  void _onMove(PointerMoveEvent e) {
    if (e.pointer == _mousePointer) {
      _onMouseMove(e);
      return;
    }
    final c = _contacts[e.pointer];
    if (c == null) return;
    final far = (e.localPosition - c.downLocal).distance > _slop;
    if (far && !c.moved) {
      c.moved = true;
      c.anchor = null;
      if (_holdPointer == e.pointer) _cancelHold();
    }
    if (c.anchor != null) return;
    final pos = ffi.cursorModel.remotePosForTouch(e.localPosition, clamp: true);
    if (pos == null) return;
    final last = _pos[c.id];
    if (last != null &&
        last.dx.round() == pos.dx.round() &&
        last.dy.round() == pos.dy.round()) {
      return;
    }
    _pos[c.id] = pos;
    _send({c.id: _stateMove});
  }

  void _onMouseMove(PointerMoveEvent e) {
    if (!_mouseDragging) {
      if ((e.localPosition - _mouseStartLocal).distance <= _dragSlop) return;
      _mouseDragging = true;
      input.sendMouse('down', MouseButtons.left);
    }
    final pos = ffi.cursorModel.remotePosForTouch(e.localPosition, clamp: true);
    if (pos == null) return;
    final last = _mouseLast;
    if (last != null &&
        last.dx.round() == pos.dx.round() &&
        last.dy.round() == pos.dy.round()) {
      return;
    }
    _mouseLast = pos;
    input.moveMouse(pos.dx, pos.dy);
  }

  void _onEnd(PointerEvent e, int state) {
    if (e.pointer == _mousePointer) {
      _mousePointer = null;
      if (_mouseDragging) {
        input.sendMouse('up', MouseButtons.left);
      } else if (state == _stateUp) {
        input.tap(MouseButtons.right);
      }
      _mouseDragging = false;
      return;
    }
    if (_holdPointer == e.pointer) _cancelHold();
    final c = _contacts.remove(e.pointer);
    if (c == null) return;
    final sent = _pos[c.id];
    _send({c.id: state});
    _pos.remove(c.id);
    _stopHeartbeatIfIdle();
    final now = DateTime.now();
    if (state == _stateUp && sent != null && !c.moved && !c.hadCompany) {
      // Kept on screen when the soft keyboard opens.
      ffi.cursorModel.touchFocus = sent;
    }
    if (state == _stateUp &&
        sent != null &&
        !c.moved &&
        !c.hadCompany &&
        now.difference(c.downTime) <= _tapMaxDuration) {
      _lastTapUp = now;
      _lastTapLocal = c.downLocal;
      _lastTapRemote = sent;
    } else {
      _lastTapUp = null;
    }
  }

  void _stopHeartbeatIfIdle() {
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
