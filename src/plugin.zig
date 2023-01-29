//
// plugin.zig
// Copyright (C) 2023 Christopher Odom <christopher.r.odom@gmail.com>
//
// Distributed under terms of the MIT license.
//
//! Contains primary definitions for the actual plugin itself
const std = @import("std");
const span = std.mem.span;
const c_allocator = std.heap.c_allocator;
const c = @import("c.zig");

clap_plugin: c.clap_plugin_t,
host:        [*c]const c.clap_host_t,
sample_rate: f64,
voices:      std.ArrayList(Voice),

const Plugin = @This();
// zig api

const Voice = struct {
    held:    bool,
    note_id:  i32,
    channel: i16,
    key:     i16,
    phase:   f32,
};

pub fn process_event(plugin: *Plugin, event: [*c]const c.clap_event_header_t) void {
    if(event.*.space_id == c.CLAP_CORE_EVENT_SPACE_ID) {
        if(
            event.*.type == c.CLAP_EVENT_NOTE_ON or
            event.*.type == c.CLAP_EVENT_NOTE_OFF or
            event.*.type == c.CLAP_EVENT_NOTE_CHOKE
        ) {
            const note_event = @ptrCast([*c]const c.clap_event_note_t, @alignCast(@alignOf([*c]const c.clap_event_note_t), event));

            // If the event matches a voice, then it must be a note release
            var i: usize = 0;
            while(i < plugin.voices.items.len) : (i+=1) {
                var voice = &plugin.voices.items[i];

                if((note_event.*.key == -1 or voice.key == note_event.*.key)
                and (note_event.*.note_id == -1 or voice.note_id == note_event.*.note_id)
                and (note_event.*.channel == -1 or voice.channel == note_event.*.channel)
                ) {
                    if(event.*.type == c.CLAP_EVENT_NOTE_CHOKE) {
                        _ = plugin.voices.swapRemove(i);
                        if(i != 0) i -= 1;
                    } else {
                        voice.held = false;
                    }
                }
            }


            // If this is a note on event, create a new voice
            if(event.*.type == c.CLAP_EVENT_NOTE_ON) {
                const voice = Voice {
                    .held = true,
                    .note_id = note_event.*.note_id,
                    .channel = note_event.*.channel,
                    .key = note_event.*.key,
                    .phase = 0.0,
                };

                plugin.voices.append(voice) catch unreachable;
            }
        }
    }
}

pub fn render_audio(plugin: *Plugin, start: u32, end: u32, outputL: [*c]f32, outputR: [*c]f32) void {
    var index: usize = start;
    while(index < end) : (index += 1) {
        var sum: f32 = 0.0;

        for(plugin.voices.items) |*voice| {
            if(!voice.held) continue;

            sum += std.math.sin(voice.phase * 2.0 * std.math.pi) * 0.2;
            voice.phase += @floatCast(f32, 440.0 * std.math.exp2((@intToFloat(f32, voice.key) - 57.0) / 12.0) / plugin.sample_rate);
            voice.phase -= std.math.floor(voice.phase);
        }

        outputL[index] = sum;
        outputR[index] = sum;
    }
}

const ExtensionNotePorts = struct {
    const extension = c.clap_plugin_note_ports_t {
        .count = count,
        .get = get,
    };

    fn count(_: [*c]const c.clap_plugin_t, is_input: bool) callconv(.C) u32 {
        if(is_input) return 1;
        return 0;
    }

    fn get(_: [*c]const c.clap_plugin_t, index: u32, is_input: bool, info: [*c]c.clap_note_port_info_t) callconv(.C) bool {
        if(!is_input or index != 0) return false;
        info.*.id = 0;
        info.*.supported_dialects = c.CLAP_NOTE_DIALECT_CLAP;
        info.*.preferred_dialect = c.CLAP_NOTE_DIALECT_CLAP;
        std.log.info("{s}", .{std.fmt.bufPrintZ(info.*.name[0..], "Note Port", .{}) catch unreachable});
        return true;
    }
};

const ExtensionAudioPorts = struct {
    const extension = c.clap_plugin_audio_ports_t {
        .count = count,
        .get = get,
    };

    fn count(_: [*c]const c.clap_plugin_t, is_input: bool) callconv(.C) u32 {
        if(is_input) return 0;
        return 1;
    }

    fn get(_: [*c]const c.clap_plugin_t, index: u32, is_input: bool, info: [*c]c.clap_audio_port_info_t) callconv(.C) bool {
        if(is_input or index != 0) return false;
        info.*.id = 0;
        info.*.channel_count = 2;
        info.*.flags = c.CLAP_AUDIO_PORT_IS_MAIN;
        info.*.port_type = &c.CLAP_PORT_STEREO;
        info.*.in_place_pair = c.CLAP_INVALID_ID;
        std.log.info("{s}", .{std.fmt.bufPrintZ(info.*.name[0..], "Audio Output", .{}) catch unreachable});
        return true;
    }
};


// c api
pub const PluginClass = c.clap_plugin_t {
    .desc = &@import("root").PluginDescriptor,
    .plugin_data = null,

    .init = init_plugin,
    .destroy = destroy_plugin,
    .activate = activate_plugin,
    .deactivate = deactivate_plugin,
    .start_processing = start_processing,
    .stop_processing = stop_processing,
    .reset = reset,
    .process = process,
    .get_extension = get_extension,
    .on_main_thread = on_main_thread,
};

fn init_plugin(_plugin: [*c]const c.clap_plugin_t)
callconv(.C) bool {
    var plugin = @ptrCast(*Plugin, @alignCast(@alignOf(Plugin), _plugin.*.plugin_data));
    plugin.voices = std.ArrayList(Voice).init(c_allocator);
    return true;
}


fn destroy_plugin(_plugin: [*c]const c.clap_plugin_t)
callconv(.C) void {
    var plugin = @ptrCast(*Plugin, @alignCast(8, _plugin.*.plugin_data));
    plugin.voices.deinit();
}

fn activate_plugin(_plugin: [*c]const c.clap_plugin_t, sample_rate: f64, min_frames_count: u32, max_frames_count: u32)
callconv(.C) bool {
    _ = min_frames_count; _ = max_frames_count;
    var plugin = @ptrCast(*Plugin, @alignCast(8, _plugin.*.plugin_data));
    plugin.sample_rate = sample_rate;
    return true;
}

fn deactivate_plugin(_plugin: [*c]const c.clap_plugin_t)
callconv(.C) void {
    var plugin = @ptrCast(*Plugin, @alignCast(8, _plugin.*.plugin_data));
    _ = plugin;
}

fn start_processing(_plugin: [*c]const c.clap_plugin_t)
callconv(.C) bool {
    var plugin = @ptrCast(*Plugin, @alignCast(8, _plugin.*.plugin_data));
    _ = plugin;
    return true;
}

fn stop_processing(_plugin: [*c]const c.clap_plugin_t)
callconv(.C) void {
    var plugin = @ptrCast(*Plugin, @alignCast(8, _plugin.*.plugin_data));
    _ = plugin;
}

fn reset(_plugin: [*c]const c.clap_plugin_t)
callconv(.C) void {
    var plugin = @ptrCast(*Plugin, @alignCast(8, _plugin.*.plugin_data));
    plugin.voices.deinit();
}

fn process(_plugin: [*c]const c.clap_plugin_t, _process: [*c]const c.clap_process)
callconv(.C) c.clap_process_status {
    var plugin = @ptrCast(*Plugin, @alignCast(8, _plugin.*.plugin_data));

    std.testing.expect(_process.*.audio_outputs_count == 1) catch unreachable;
    std.testing.expect(_process.*.audio_inputs_count == 0) catch unreachable;

    const frame_count = _process.*.frames_count;
    const input_event_count = _process.*.in_events.*.size.?(_process.*.in_events);

    var event_i: u32 = 0;
    var next_event_frame : u32 = if(input_event_count != 0) 0 else frame_count;


    var i: u32 = 0;
    while(i < frame_count) {
        while(event_i < input_event_count and next_event_frame == i) {
            const event = _process.*.in_events.*.get.?(_process.*.in_events, event_i);

            if(event.*.time != i) {
                next_event_frame = event.*.time;
                break;
            }

            plugin.process_event(event);
            event_i += 1;

            if(event_i == input_event_count) {
                next_event_frame = frame_count;
                break;
            }
        }

        plugin.render_audio(i, next_event_frame, _process.*.audio_outputs[0].data32[0], _process.*.audio_outputs[0].data32[1]);
        i = next_event_frame;
    }

    i = 0;
    while(i < plugin.voices.items.len) : (i+=1) {
        var voice = &plugin.voices.items[i];
        if(!voice.held) {
            var event = std.mem.zeroes(c.clap_event_note_t);
            event.header = .{
                    .size = @sizeOf(c.clap_event_note_t),
                    .time = 0,
                    .space_id = c.CLAP_CORE_EVENT_SPACE_ID,
                    .type = c.CLAP_EVENT_NOTE_END,
                    .flags = 0,
            };
            event.key = voice.key;
            event.note_id = voice.note_id;
            event.channel = voice.channel;
            event.port_index = 0;
            _ = _process.*.out_events.*.try_push.?(_process.*.out_events, &event.header);
            _ = plugin.voices.swapRemove(i);
            if(i != 0) i-=1;
        }
    }

    return c.CLAP_PROCESS_CONTINUE;
}

fn get_extension(_plugin: [*c]const c.clap_plugin_t, id: [*c]const u8)
callconv(.C) ?*const anyopaque{
    var plugin = @ptrCast(*Plugin, @alignCast(8, _plugin.*.plugin_data));
    _ = plugin;
    _ = id;
    if(std.mem.eql(u8, span(id), c.CLAP_EXT_NOTE_PORTS[0..])) {
        return @ptrCast(?*const anyopaque, &ExtensionNotePorts.extension);
    }
    if(std.mem.eql(u8, span(id), c.CLAP_EXT_AUDIO_PORTS[0..])) {
        return @ptrCast(?*const anyopaque, &ExtensionAudioPorts.extension);
    }
    return null;
}

fn on_main_thread(_plugin: [*c]const c.clap_plugin_t)
callconv(.C) void {
    var plugin = @ptrCast(*Plugin, @alignCast(8, _plugin.*.plugin_data));
    _ = plugin;
}
