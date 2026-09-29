'use strict';

var libQ = require('kew');
var fs = require('fs-extra');
var dbus = require('dbus-next');

// When a phone streams over A2DP, the audio reaches the DAC through
// bluealsa-aplay, but Volumio knows nothing about it: the screen stays empty
// and the transport buttons do nothing. Everything needed to fix that is on
// the other end of the same Bluetooth link, in AVRCP, which BlueZ exposes as
// org.bluez.MediaPlayer1 - title, artist, album, duration, position, status,
// and Play/Pause/Stop/Next/Previous. This plugin mirrors that into Volumio's
// player and sends the buttons back the other way.

var BLUEZ = 'org.bluez';
var PLAYER_IFACE = 'org.bluez.MediaPlayer1';
var PROPS_IFACE = 'org.freedesktop.DBus.Properties';
var OBJECT_MANAGER = 'org.freedesktop.DBus.ObjectManager';
var SERVICE = 'bt_receiver';

// Position only changes on its own while playing; AVRCP does not push it.
var TICK_MS = 1000;

function isAvrcp(path) {
    return path.indexOf('/avrcp/') >= 0;
}

module.exports = btReceiver;

function btReceiver(context) {
    var self = this;

    self.context = context;
    self.commandRouter = self.context.coreCommand;
    self.logger = self.context.logger;
    self.configManager = self.context.configManager;

    self.bus = false;
    self.player = false;
    self.playerPath = '';
    self.track = {};
    self.status = 'stop';
    self.position = 0;
    self.volatile = false;
    self.ticker = false;
    // Whether we have already stopped whatever Volumio was playing for this
    // phone session; doing it once per session, not once per state push.
    self.tookOver = false;
}

btReceiver.prototype.onVolumioStart = function () {
    var self = this;

    var configFile = self.commandRouter.pluginManager.getConfigurationFile(this.context, 'config.json');
    self.config = new (require('v-conf'))();
    self.config.loadFile(configFile);

    return libQ.resolve();
};

// Volumio routes pause and stop to whoever holds the volatile player, but
// not play: volumioPlay unconditionally drops the volatile owner and starts
// the queue instead. The UI hides this by sending toggle, which does check
// state.volatile - but anything driving Volumio from outside, Home Assistant
// included, sends a plain play and the phone just stays paused.
//
// So volumioPlay is wrapped: while we own the player and a phone is
// attached, play means "resume the phone"; in every other case the original
// runs untouched. onStop puts it back.
btReceiver.prototype.interceptPlay = function () {
    var self = this;
    var router = self.commandRouter;

    if (router.__btReceiverPlay) {
        return;
    }

    router.__btReceiverPlay = router.volumioPlay;
    router.volumioPlay = function (N) {
        var machine = router.stateMachine;
        if (self.player && machine && machine.isVolatile && machine.volatileService === SERVICE) {
            self.logger.info('[bt_receiver] play перехвачен, возобновляю телефон');
            return self.play();
        }
        return router.__btReceiverPlay.call(router, N);
    };
};

btReceiver.prototype.restorePlay = function () {
    var self = this;
    var router = self.commandRouter;

    if (router.__btReceiverPlay) {
        router.volumioPlay = router.__btReceiverPlay;
        delete router.__btReceiverPlay;
    }
};

btReceiver.prototype.onStart = function () {
    var self = this;

    self.logger.info('[bt_receiver] onStart');
    self.interceptPlay();

    // Volumio waits on this promise before loading the next plugin, so the
    // D-Bus connection deliberately is not part of it. It takes about 90ms
    // in practice, but a bus that is slow, busy or absent would otherwise
    // hold up the whole startup - and a media player is not worth that.
    self.connect().then(function () {
        self.logger.info('[bt_receiver] подключение к D-Bus завершено');
    }).catch(function (err) {
        self.logger.error('[bt_receiver] не удалось подключиться к D-Bus: ' + (err && err.stack ? err.stack : err));
    });

    return libQ.resolve();
};

btReceiver.prototype.onStop = function () {
    var self = this;

    self.restorePlay();
    self.stopTicker();
    self.releasePlayer();
    if (self.bus) {
        try { self.bus.disconnect(); } catch (e) { /* already gone */ }
        self.bus = false;
    }

    return libQ.resolve();
};

btReceiver.prototype.onRestart = function () {
    return libQ.resolve();
};

btReceiver.prototype.getConfigurationFiles = function () {
    return ['config.json'];
};

// ------------------------------------------------------------------- D-Bus

btReceiver.prototype.connect = async function () {
    var self = this;

    self.logger.info('[bt_receiver] подключаюсь к системной шине');
    self.bus = dbus.systemBus();

    var root = await self.bus.getProxyObject(BLUEZ, '/');
    self.logger.info('[bt_receiver] получен корневой объект org.bluez');
    var manager = root.getInterface(OBJECT_MANAGER);

    manager.on('InterfacesAdded', function (path, interfaces) {
        if (!interfaces[PLAYER_IFACE]) {
            return;
        }
        // Ignore the MCP twin unless nothing better is attached - see below.
        if (!isAvrcp(path) && self.player) {
            return;
        }
        self.logger.info('[bt_receiver] появился плеер: ' + path);
        self.attach(path).catch(function (err) {
            self.logger.error('[bt_receiver] attach: ' + err);
        });
    });

    manager.on('InterfacesRemoved', function (path, interfaces) {
        if (interfaces.indexOf(PLAYER_IFACE) >= 0 && path === self.playerPath) {
            self.logger.info('[bt_receiver] плеер отключился: ' + path);
            self.releasePlayer();
        }
    });

    // A phone may already be connected when the plugin starts.
    var objects = await manager.GetManagedObjects();
    self.logger.info('[bt_receiver] объектов в BlueZ: ' + Object.keys(objects).length);

    var candidates = Object.keys(objects).filter(function (path) {
        return objects[path][PLAYER_IFACE];
    });

    // A phone shows up twice: once under avrcp, which carries the title,
    // artist and transport we want, and once under mcp - the BLE Media
    // Control Profile - which reports nothing. Taking the first match found
    // mcp and produced a player that never said a word.
    var chosen = candidates.filter(isAvrcp)[0] || candidates[0];

    if (chosen) {
        self.logger.info('[bt_receiver] выбран плеер: ' + chosen +
                         ' (кандидатов: ' + candidates.length + ')');
        await self.attach(chosen);
    } else {
        self.logger.info('[bt_receiver] плеер не подключён, жду');
    }
};

btReceiver.prototype.attach = async function (path) {
    var self = this;

    self.releasePlayer();

    var object = await self.bus.getProxyObject(BLUEZ, path);
    self.player = object.getInterface(PLAYER_IFACE);
    self.playerPath = path;

    var properties = object.getInterface(PROPS_IFACE);
    var all = await properties.GetAll(PLAYER_IFACE);
    self.absorb(all);

    properties.on('PropertiesChanged', function (iface, changed) {
        if (iface !== PLAYER_IFACE) {
            return;
        }
        self.absorb(changed);
        self.pushState();
    });

    self.pushState();
};

btReceiver.prototype.releasePlayer = function () {
    var self = this;

    if (!self.player) {
        return;
    }

    self.player = false;
    self.playerPath = '';
    self.track = {};
    self.status = 'stop';
    self.position = 0;
    self.tookOver = false;
    self.stopTicker();
    self.unsetVolatile();
};

// D-Bus hands values back wrapped in variants; unwrap the ones we use.
btReceiver.prototype.absorb = function (properties) {
    var self = this;

    if (properties.Status) {
        self.status = properties.Status.value;
    }
    if (properties.Position) {
        self.position = properties.Position.value;
    }
    if (properties.Track) {
        var track = properties.Track.value;
        self.track = {
            title: track.Title ? track.Title.value : '',
            artist: track.Artist ? track.Artist.value : '',
            album: track.Album ? track.Album.value : '',
            duration: track.Duration ? Math.round(track.Duration.value / 1000) : 0
        };
    }
};

// ------------------------------------------------------------------- state

function volumioStatus(avrcpStatus) {
    if (avrcpStatus === 'playing') {
        return 'play';
    }
    if (avrcpStatus === 'paused') {
        return 'pause';
    }
    return 'stop';
}

btReceiver.prototype.buildState = function () {
    var self = this;

    return {
        status: volumioStatus(self.status),
        service: SERVICE,
        title: self.track.title || 'Bluetooth',
        artist: self.track.artist || '',
        album: self.track.album || '',
        albumart: '/albumart?sourceicon=music_service/bt_receiver/bt.png',
        uri: '',
        trackType: 'Bluetooth',
        seek: self.position,
        duration: self.track.duration || 0,
        samplerate: '44.1 kHz',
        bitdepth: '16 bit',
        channels: 2
    };
};

btReceiver.prototype.claim = function () {
    var self = this;

    // Volumio's "volatile" mode is how an external player - AirPlay, Spotify
    // Connect and now this - takes over the screen without owning a queue.
    //
    // Claiming once is not enough: unSetVolatile() clears the owner, and
    // upnp, airplay and the core all call it. Once cleared, Volumio no longer
    // knows whose transport buttons these are and logs "No play method for
    // volatile plugin undefined". Re-claiming is two assignments, so it is
    // done on every push rather than tracked.
    self.commandRouter.stateMachine.setVolatile({
        service: SERVICE,
        callback: self.unsetVolatile.bind(self)
    });
    self.volatile = true;
};

btReceiver.prototype.pushState = function () {
    var self = this;

    if (!self.player) {
        return;
    }

    var state = self.buildState();

    // syncState only accepts a volatile update while the status is play or
    // pause; a stop falls through to the queue check and is rejected as
    // coming from "a service different from the one supposed to be playing".
    // So a stopped phone hands the player back instead of shouting into a
    // log nobody reads.
    if (state.status === 'stop') {
        self.stopTicker();
        self.unsetVolatile();
        return;
    }

    // Taking over from whatever Volumio was playing, once, the way
    // airplay_emulation does it - otherwise both would be playing at once.
    if (state.status === 'play' && !self.tookOver) {
        self.tookOver = true;
        try {
            self.commandRouter.volumioStop();
        } catch (e) {
            self.logger.error('[bt_receiver] volumioStop: ' + e);
        }
    }

    self.claim();
    self.commandRouter.servicePushState(state, SERVICE);
    self.startTicker();
};

// Runs for as long as a phone is attached, not just while it plays. Two jobs:
// AVRCP never pushes Position on its own, so the progress bar would stand
// still for a whole track; and a paused player still has to keep re-claiming
// the volatile slot, or the play button stops working the moment something
// else clears it.
btReceiver.prototype.startTicker = function () {
    var self = this;

    if (self.ticker) {
        return;
    }

    self.ticker = setInterval(function () {
        if (!self.player || volumioStatus(self.status) === 'stop') {
            self.stopTicker();
            return;
        }
        if (volumioStatus(self.status) === 'play') {
            self.position += TICK_MS;
        }
        self.claim();
        self.commandRouter.servicePushState(self.buildState(), SERVICE);
    }, TICK_MS);
};

btReceiver.prototype.stopTicker = function () {
    var self = this;

    if (self.ticker) {
        clearInterval(self.ticker);
        self.ticker = false;
    }
};

btReceiver.prototype.unsetVolatile = function () {
    var self = this;

    if (!self.volatile) {
        return libQ.resolve();
    }
    self.volatile = false;
    self.commandRouter.stateMachine.unSetVolatile();

    return libQ.resolve();
};

// --------------------------------------------------------------- transport

btReceiver.prototype.command = function (name) {
    var self = this;
    var defer = libQ.defer();

    if (!self.player) {
        defer.resolve();
        return defer.promise;
    }

    self.player[name]().then(function () {
        defer.resolve();
    }).catch(function (err) {
        self.logger.error('[bt_receiver] ' + name + ': ' + err);
        defer.resolve();
    });

    return defer.promise;
};

btReceiver.prototype.play = function () {
    return this.command('Play');
};

btReceiver.prototype.pause = function () {
    return this.command('Pause');
};

btReceiver.prototype.resume = function () {
    return this.command('Play');
};

btReceiver.prototype.stop = function () {
    return this.command('Stop');
};

btReceiver.prototype.next = function () {
    return this.command('Next');
};

btReceiver.prototype.previous = function () {
    return this.command('Previous');
};

// ---------------------------------------------------------------- settings

btReceiver.prototype.getUIConfig = function () {
    var self = this;
    var defer = libQ.defer();
    var lang = self.commandRouter.sharedVars.get('language_code');

    self.commandRouter.i18nJson(
        __dirname + '/i18n/strings_' + lang + '.json',
        __dirname + '/i18n/strings_en.json',
        __dirname + '/UIConfig.json'
    ).then(function (uiconf) {
        defer.resolve(uiconf);
    }).fail(function () {
        defer.reject(new Error());
    });

    return defer.promise;
};

btReceiver.prototype.setUIConfig = function () {
    return libQ.resolve();
};

btReceiver.prototype.getConf = function (name) {
    return this.config.get(name);
};

btReceiver.prototype.setConf = function (name, value) {
    this.config.set(name, value);
};
