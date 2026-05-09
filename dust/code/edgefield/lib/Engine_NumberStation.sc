Engine_EdgeField : CroneEngine {

    var <masterSynth;
    var <carrierSynth;
    var <noiseSynth;

    var <voiceBus;
    var <ambientBus;

    var digit_done_flag;

    // distance state (0.0 - 1.0)
    var distanceVal;

    *new { arg context, doneCallback;
        ^super.new(context, doneCallback);
    }

    alloc {

        // =====================================================
        // BUSSES
        // =====================================================

        voiceBus   = Bus.audio(context.server, 2);
        ambientBus = Bus.audio(context.server, 2);

        digit_done_flag = 0;
        distanceVal     = 0.3;

        // =====================================================
        // POLL
        // =====================================================

        this.addPoll(\digit_done, {
            var val = digit_done_flag;
            digit_done_flag = 0;
            val
        });

        // =====================================================
        // IONOSPHERIC CARRIER
        // Narrowband sine hum with slow pitch + amplitude flutter
        // Models shortwave carrier bleed rather than a synth pad
        // =====================================================

        carrierSynth = {

            arg
                vol      = 0.0,
                freq     = 4800,
                pitchLFO = 0.08,
                ampLFO   = 0.15;

            var freqSmooth;
            var volSmooth;
            var pitchMod;
            var ampMod;
            var sig;

            // smooth incoming freq and vol to prevent stepping
            freqSmooth = freq.lag(0.08);
            volSmooth  = vol.lag(0.05);

            // slow ionospheric pitch wander
            pitchMod = LFNoise1.kr(pitchLFO).range(
                freqSmooth * 0.998,
                freqSmooth * 1.002
            );

            // slow amplitude fade (troposcatter flutter)
            ampMod = LFNoise1.kr(ampLFO).range(0.3, 1.0);

            sig = SinOsc.ar(pitchMod) * ampMod * volSmooth;

            // narrow bandpass to keep it tonal not bassy
            sig = BPF.ar(sig, freqSmooth, 0.02);

            Out.ar(ambientBus, sig ! 2);

        }.play(context.server, addAction: \addToHead);

        // =====================================================
        // SHORTWAVE STATIC
        // BPF white noise + sparse impulse pops
        // Models band noise between stations
        // =====================================================

        noiseSynth = {

            arg
                vol     = 0.0,
                popRate = 1.2,
                center  = 2400;

            var volSmooth;
            var band;
            var pops;
            var sig;

            // smooth vol to prevent stepping from Lua LFO updates
            volSmooth = vol.lag(0.08);

            // band-limited hiss
            band = BPF.ar(WhiteNoise.ar(1.0), center, 0.8) * 0.6;

            // sparse sharp pops (ionospheric clicks)
            pops = Dust.ar(popRate) * 0.4;
            pops = HPF.ar(pops, 1200);

            sig = (band + pops) * volSmooth;

            Out.ar(ambientBus, sig ! 2);

        }.play(context.server, addAction: \addToHead);

        // =====================================================
        // MASTER FX
        // Voice bandpass + bitcrush + phaser -> mix with ambient
        // =====================================================

        masterSynth = {

            arg
                bandwidth    = 2400,
                locut        = 300,
                bitcrush     = 0.0,
                phaserFreq   = 0.15,
                ambientVol   = 0.4,
                trailWet     = 0.0,
                trailTime    = 0.45,
                trailFeedback = 0.0;

            var voiceIn;
            var ambientIn;
            var sig;
            var trail;
            var wetSmooth;
            var fbSmooth;

            voiceIn   = In.ar(voiceBus,   2);
            ambientIn = In.ar(ambientBus, 2);

            // radio bandpass
            sig = HPF.ar(voiceIn, locut);
            sig = LPF.ar(sig, bandwidth);

            // soft bitcrush (only active above threshold)
            sig = Select.ar(
                bitcrush > 0.001,
                [
                    sig,
                    sig.round(bitcrush)
                ]
            );

            // mild phaser for that slight phase-shift keying feel
            sig = AllpassN.ar(
                sig,
                0.02,
                SinOsc.kr(phaserFreq).range(0.001, 0.009),
                0.08
            );

            // persistent echo with controllable wet/feedback
            // normally dry; cranked on K2 kill for trailing decay
            wetSmooth = trailWet.lag(0.1);
            fbSmooth  = trailFeedback.lag(0.1);

            trail = CombL.ar(
                sig,
                2.0,
                trailTime,
                fbSmooth * 8.0  // decaytime from feedback 0-1
            );

            sig = sig + (trail * wetSmooth);

            sig = sig + (ambientIn * ambientVol);

            Out.ar(0, Limiter.ar(sig * 0.7, 0.95));

        }.play(context.server, addAction: \addToTail);

        // =====================================================
        // PLAY VOICE
        // "sfff" : path, drift, fx_mode, fx_param
        //
        // fx_mode:
        //   0 = dry
        //   1 = slapback  (fx_param = delay time 0.06-0.18s)
        //   2 = echo      (fx_param = feedback  0.2-0.8)
        //   3 = reverb    (fx_param = room size 0.1-0.9)
        //   4 = distort   (fx_param = drive     0.5-4.0)
        // =====================================================

        this.addCommand("play_voice", "sfff", { arg msg;

            var path    = msg[1].asString;
            var drift   = msg[2].asFloat;
            var fxMode  = msg[3].asFloat.asInteger;
            var fxParam = msg[4].asFloat;

            Buffer.read(context.server, path, action: { |buf|

                {
                    var rate;
                    var sig;

                    rate =
                        BufRateScale.kr(buf)
                        * LFNoise1.kr(2).range(
                            1.0 - drift,
                            1.0 + drift
                        );

                    sig = PlayBuf.ar(
                        1,
                        buf.bufnum,
                        rate,
                        doneAction: 2
                    );

                    // --- FX branch ---

                    sig = Select.ar(fxMode, [

                        // 0: dry
                        sig,

                        // 1: slapback — single short echo, no feedback
                        (sig + DelayN.ar(sig, 0.3, fxParam.clip(0.03, 0.25))) * 0.7,

                        // 2: echo with feedback
                        (sig + CombL.ar(sig, 1.0, fxParam.clip(0.05, 0.9).lag(0.1), 2.0)) * 0.6,

                        // 3: freeverb room
                        FreeVerb.ar(sig, fxParam.clip(0.1, 0.95), fxParam.clip(0.1, 0.9), 0.5),

                        // 4: soft clip distortion
                        (sig * (fxParam.clip(0.5, 4.0) * 4)).tanh * 0.4

                    ]);

                    Out.ar(voiceBus, Pan2.ar(sig, 0));

                }.play(context.server);

                // flag done + free buffer after playback
                SystemClock.sched(buf.duration + 0.5, {
                    digit_done_flag = 1;
                    buf.free;
                    nil
                });
            });
        });

        // =====================================================
        // PARAM COMMANDS
        // =====================================================

        this.addCommand("carrier_vol", "f", { arg msg;
            carrierSynth.set(\vol, msg[1]);
        });

        this.addCommand("carrier_freq", "f", { arg msg;
            carrierSynth.set(\freq, msg[1]);
        });

        this.addCommand("carrier_drift", "f", { arg msg;
            carrierSynth.set(\pitchLFO, msg[1]);
            carrierSynth.set(\ampLFO,   msg[1] * 1.8);
        });

        this.addCommand("noise_vol", "f", { arg msg;
            noiseSynth.set(\vol, msg[1]);
        });

        this.addCommand("noise_pops", "f", { arg msg;
            noiseSynth.set(\popRate, msg[1]);
        });

        this.addCommand("master_bandwidth", "f", { arg msg;
            masterSynth.set(\bandwidth, msg[1]);
        });

        this.addCommand("master_crush", "f", { arg msg;
            masterSynth.set(\bitcrush, msg[1]);
        });

        this.addCommand("master_ambient", "f", { arg msg;
            masterSynth.set(\ambientVol, msg[1]);
        });

        // Distance meta-control
        // Drives: noise up, carrier up, bandwidth down,
        //         ambient mix up — all from one 0.0-1.0 float
        this.addCommand("distance", "f", { arg msg;

            var d = msg[1].clip(0.0, 1.0);

            distanceVal = d;

            carrierSynth.set(\vol,      d * 0.18);
            noiseSynth.set(\vol,        d * 0.22);
            noiseSynth.set(\popRate,    d * 4.0 + 0.3);
            masterSynth.set(\bandwidth, 4000 - (d * 2800));  // 4000->1200
            masterSynth.set(\ambientVol, d * 0.55);
        });
        // Kill trail — spike echo wet+feedback, then fade to silence
        // duration: seconds for trail to decay
        this.addCommand("kill_trail", "f", { arg msg;

            var dur = msg[1];

            // crank echo wet and feedback immediately
            masterSynth.set(\trailWet,      0.9);
            masterSynth.set(\trailFeedback, 0.85);

            // after trail duration, fade back to dry
            SystemClock.sched(dur, {
                masterSynth.set(\trailWet,      0.0);
                masterSynth.set(\trailFeedback, 0.0);
                masterSynth.set(\ambientVol,    distanceVal * 0.55);
                nil
            });
        });

        this.addCommand("trail_clear", "f", { arg msg;
            masterSynth.set(\trailWet,      0.0);
            masterSynth.set(\trailFeedback, 0.0);
        });

    }

    // =========================================================
    // FREE
    // =========================================================

    free {
        masterSynth.free;
        carrierSynth.free;
        noiseSynth.free;
        voiceBus.free;
        ambientBus.free;
    }
}