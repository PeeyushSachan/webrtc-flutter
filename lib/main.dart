import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'call_service.dart';

void main() => runApp(const CallApp());

class CallApp extends StatefulWidget {
  const CallApp({super.key});
  @override
  State<CallApp> createState() => _CallAppState();
}

class _CallAppState extends State<CallApp> {
  final _local = RTCVideoRenderer();
  final _remote = RTCVideoRenderer();

  // Change these when running on two devices
  final String myId = 'alice';  // device A: 'alice', device B: 'bob'
  final String peerId = 'bob';

  final String wsUrl = 'wss://webrtc-1-ad8ace118f66.herokuapp.com/';
  final String? signalingSecret = null; // set if you configured SIGNALING_SECRET

  late CallService call;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _local.initialize();
    await _remote.initialize();

    call = CallService(
      userId: myId,
      wsUrl: wsUrl,
      signalingSecret: signalingSecret,
    );

    // Explicit closures (avoid "void value can't be used" issues)
    call.onLocalStream = (MediaStream? s) {
      setState(() {
        _local.srcObject = s;
      });
    };

    call.onRemoteStream = (MediaStream? s) {
      setState(() {
        _remote.srcObject = s;
      });
    };

    call.onIncomingOffer = ({
      required String fromUserId,
      required String sdp,
      required bool video,
    }) {
      // Simple incoming call dialog
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          title: const Text('Incoming call'),
          content: Text('From: $fromUserId  •  Video: $video'),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                call.acceptCall(fromUserId: fromUserId, sdp: sdp, video: video);
              },
              child: const Text('Answer'),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: const Text('Decline'),
            ),
          ],
        ),
      );
    };

    await call.connectSignaling();
    setState(() {}); // rebuild app bar state label
  }

  @override
  void dispose() {
    _local.dispose();
    _remote.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: ValueListenableBuilder<String>(
            valueListenable: call.callState,
            builder: (_, state, __) => Text('1:1 Call • $state'),
          ),
        ),
        body: Column(
          children: [
            Expanded(
              child: Container(
                color: Colors.black12,
                child: RTCVideoView(
                  _remote,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                ),
              ),
            ),
            Expanded(
              child: Container(
                color: Colors.black12,
                child: RTCVideoView(
                  _local,
                  mirror: true,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Wrap(
                alignment: WrapAlignment.center,
                spacing: 12,
                children: [
                  ElevatedButton(
                    onPressed: () => call.startCall(peerId, video: true),
                    child: const Text('Call (Video)'),
                  ),
                  ElevatedButton(
                    onPressed: () => call.startCall(peerId, video: false),
                    child: const Text('Call (Audio)'),
                  ),
                  ElevatedButton(
                    onPressed: () => call.switchMic(false),
                    child: const Text('Mute'),
                  ),
                  ElevatedButton(
                    onPressed: () => call.endCall(),
                    child: const Text('Hang up'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
