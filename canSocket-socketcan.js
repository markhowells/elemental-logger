"use strict";
// Drop-in replacement for canboatjs's canSocket.js.
// canboatjs's own canSocket.node uses uv_poll_t which does not fire on CAN
// sockets under Node.js v24. This wrapper uses the socketcan npm module
// (which uses a thread-based approach that works correctly) and exposes the
// same CanChannel API that canbus.js expects.
const { EventEmitter } = require('events');
const socketcan = require('/home/node/socketcan-pkg/node_modules/socketcan');

class CanChannel extends EventEmitter {
  constructor(ifname) {
    super();
    this._ch = socketcan.createRawChannel(ifname, false);
    this._stopped = false;
  }

  start() {
    this._stopped = false;
    this._ch.addListener('onMessage', (msg) => {
      if (!this._stopped) {
        this.emit('onMessage', { id: msg.id, data: Buffer.from(msg.data) });
      }
    });
    this._ch.start();
  }

  stop() {
    if (this._stopped) return;
    this._stopped = true;
    try { this._ch.stop(); } catch (_) {}
    this.emit('onStopped');
  }

  send(msg) {
    if (!this._stopped) {
      this._ch.send({ id: msg.id, ext: !!msg.ext, data: msg.data });
    }
  }
}

exports.CanChannel = CanChannel;
