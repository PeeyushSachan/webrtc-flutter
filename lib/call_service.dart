import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

typedef StreamCallback = void Function(MediaStream? stream);

typedef IncomingOffer = void Function({
  required String fromUserId,
  required String sdp,
  required bool video,
});

class CallService {
  final String userId;
  final String wsUrl;                 // e.g. wss://webrtc-...herokuapp.com/
  final String? signalingSecret;      // optional: if you set SIGNALING_SECRET
  final List<Map<String, dynamic>> iceServers;

  WebSocketChannel? _ws;
  RTCPeerConnection? _pc;
  MediaStream? _localStream;

  // UI hooks
  final ValueNotifier<String> callState = ValueNotifier('idle'); // idle|ringing|connecting|connected|ended
  StreamCallback? onLocalStream;
  StreamCallback? onRemoteStream;
  IncomingOffer? onIncomingOffer;

  CallService({
    required this.userId,
    required this.wsUrl,
    this.signalingSecret,
    this.iceServers = const [
      {"urls": "stun:stun.l.google.com:19302"},
      // Add TURN here for production reliability
      // {
      //   "urls": ["turn:YOUR_TURN_IP:3478?transport=udp","turn:YOUR_TURN_IP:3478?transport=tcp"],
      //   "username": "demo",
      //   "credential": "demo_pass"
      // }
    ],
  });

  // ------------------ signaling ------------------
  Future<void> connectSignaling() async {
    _ws?.sink.close();
    _ws = WebSocketChannel.connect(Uri.parse(wsUrl));
    _ws!.stream.listen(_onSignal, onError: (e) => debugPrint('WS error: $e'), onDone: () {
      debugPrint('WS closed');
    });

    if (signalingSecret != null && signalingSecret!.isNotEmpty) {
      _send({"type": "hello", "secret": signalingSecret});
    }
    _send({"type": "register", "userId": userId});
  }

  void _send(Map data) => _ws?.sink.add(jsonEncode(data));

  // ------------------ media & peer ------------------
  Future<MediaStream> _getUserMedia({required bool video}) async {
    final constraints = {
      'audio': {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
      },
      'video': video
          ? {
              'facingMode': 'user',
              'width': {'ideal': 640},
              'height': {'ideal': 480},
              'frameRate': {'ideal': 24},
            }
          : false,
    };
    return await navigator.mediaDevices.getUserMedia(constraints);
  }

  Future<void> _ensurePeer() async {
    if (_pc != null) return;

    _pc = await createPeerConnection({
      'sdpSemantics': 'unified-plan',
      'iceServers': iceServers,
    });

    _pc!.onIceCandidate = (RTCIceCandidate c) {
      if (c.candidate != null && _currentPeerId != null) {
        _send({
          "type": "ice",
          "to": _currentPeerId,
          "candidate": {
            "candidate": c.candidate,
            "sdpMid": c.sdpMid,
            "sdpMLineIndex": c.sdpMLineIndex, // <- correct name
          }
        });
      }
    };

    _pc!.onTrack = (RTCTrackEvent e) {
      if (e.streams.isNotEmpty) {
        onRemoteStream?.call(e.streams.first);
      }
    };

    _pc!.onConnectionState = (state) {
      debugPrint('PC state: $state');
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        callState.value = 'connected';
      }
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        callState.value = 'ended';
      }
    };
  }

  String? _currentPeerId;

  // ------------------ call control ------------------
  Future<void> startCall(String toUserId, {bool video = true}) async {
    _currentPeerId = toUserId;
    callState.value = 'connecting';

    await _ensurePeer();

    _localStream ??= await _getUserMedia(video: video);
    onLocalStream?.call(_localStream);
    for (final t in _localStream!.getTracks()) {
      await _pc!.addTrack(t, _localStream!);
    }

    final offer = await _pc!.createOffer({
      'offerToReceiveAudio': 1,
      'offerToReceiveVideo': video ? 1 : 0,
    });
    await _pc!.setLocalDescription(offer);

    _send({"type": "offer", "to": toUserId, "sdp": offer.sdp, "video": video});
  }

  Future<void> acceptCall({
    required String fromUserId,
    required String sdp,
    required bool video,
  }) async {
    _currentPeerId = fromUserId;

    await _ensurePeer();

    _localStream ??= await _getUserMedia(video: video);
    onLocalStream?.call(_localStream);
    for (final t in _localStream!.getTracks()) {
      await _pc!.addTrack(t, _localStream!);
    }

    await _pc!.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
    final answer = await _pc!.createAnswer({
      'offerToReceiveAudio': 1,
      'offerToReceiveVideo': video ? 1 : 0,
    });
    await _pc!.setLocalDescription(answer);

    _send({"type": "answer", "to": fromUserId, "sdp": answer.sdp});
    callState.value = 'connecting';
  }

  void endCall() {
    if (_currentPeerId != null) {
      _send({"type": "hangup", "to": _currentPeerId});
    }
    _teardown();
    callState.value = 'ended';
  }

  void switchMic(bool enabled) => _localStream?.getAudioTracks().forEach((t) => t.enabled = enabled);
  void switchCamera(bool enabled) => _localStream?.getVideoTracks().forEach((t) => t.enabled = enabled);

  // ------------------ incoming signals ------------------
  Future<void> _onSignal(dynamic raw) async {
    final m = jsonDecode(raw as String);

    switch (m['type']) {
      case 'registered':
        debugPrint('Registered as ${m['userId']}');
        break;

      case 'offer':
        callState.value = 'ringing';
        onIncomingOffer?.call(
          fromUserId: m['from'],
          sdp: m['sdp'],
          video: (m['video'] == true),
        );
        break;

      case 'answer':
        await _pc?.setRemoteDescription(RTCSessionDescription(m['sdp'], 'answer'));
        break;

      case 'ice':
        final c = m['candidate'];
        if (c != null) {
          await _pc?.addCandidate(RTCIceCandidate(
            c['candidate'],
            c['sdpMid'],
            c['sdpMLineIndex'], // <- correct name
          ));
        }
        break;

      case 'hangup':
        _teardown();
        callState.value = 'ended';
        break;

      case 'peer_unavailable':
        debugPrint('Peer unavailable: ${m['to']}');
        break;
    }
  }

  void _teardown() {
    _currentPeerId = null;

    _pc?.close();
    _pc?.dispose();
    _pc = null;

    _localStream?.getTracks().forEach((t) => t.stop());
    _localStream?.dispose();
    _localStream = null;

    // Clear UI
    onLocalStream?.call(null);
    onRemoteStream?.call(null);
  }
}
