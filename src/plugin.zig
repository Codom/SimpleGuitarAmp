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

const ef = @import("effects.zig");

const P = enum(usize) {
    Gain = 0,
    OutputGain,
    Count,
};

fn num_params() u32 {
    return @enumToInt(P.Count);
}

clap_plugin: c.clap_plugin_t,
host:        [*c]const c.clap_host_t,
sample_rate: f64,

filters:     std.ArrayList(ef.biquad_d2) = undefined,

// Parameter state
params:       [num_params()]f32,
main_params:  [num_params()]f32,
changed:      [num_params()]bool,
main_changed: [num_params()]bool,
mut:          std.Thread.Mutex,

const Plugin = @This();
// zig api

pub fn create_plugin() Plugin {
    var ret: Plugin = undefined;
    ret.clap_plugin = std.mem.zeroes(c.clap_plugin_t);
    ret.host = null;
    ret.params = .{0} ** num_params();
    ret.main_params = .{0} ** num_params();
    ret.main_changed = .{false} ** num_params();
    ret.mut = .{};
    return ret;
}

pub fn sync_main_to_audio(plugin: *Plugin, out: [*c]const c.clap_output_events_t) void {
    plugin.mut.lock();
    defer plugin.mut.unlock();

    var i: u32 = 0;
    while(i < num_params()) : (i += 1) {
        if(plugin.main_changed[i]) {
            plugin.params[i] = plugin.main_params[i];
            plugin.main_changed[i] = false;

            var event = std.mem.zeroes(c.clap_event_param_value_t);
            event.header = .{
                .size = @sizeOf(c.clap_event_param_value),
                .time = 0,
                .space_id = c.CLAP_CORE_EVENT_SPACE_ID,
                .type = c.CLAP_EVENT_PARAM_VALUE,
                .flags = 0,
            };
            event.param_id = i;
            event.cookie = null;
            event.note_id = -1;
            event.port_index = -1;
            event.channel = -1;
            event.key = -1;
            event.value = plugin.params[i];
            _ = out.*.try_push.?(out, &event.header);
        }
    }
    // mutex handled in defer clause
}

pub fn sync_audio_to_main(plugin: *Plugin) bool {
    plugin.mut.lock();
    defer plugin.mut.unlock();

    var i: usize = 0;
    while(i < num_params()) : (i += 1) {
        if(plugin.changed[i]) {
            plugin.main_params[i] = plugin.params[i];
            plugin.changed[i] = false;
            return true;
        }
    }
    return false;
}

pub fn process_event(plugin: *Plugin, event: [*c]const c.clap_event_header_t) void {
    if(event.*.space_id == c.CLAP_CORE_EVENT_SPACE_ID) {
        if(event.*.type == c.CLAP_EVENT_PARAM_VALUE) {
            const value_ev = ptr_as(*const c.clap_event_param_value_t, event);
            var i: u32 = value_ev.*.param_id;

            plugin.mut.lock();
                plugin.params[i] = @floatCast(f32, value_ev.value);
                plugin.changed[i] = true;
            plugin.mut.unlock();
        }
    //     if(
    //         event.*.type == c.CLAP_EVENT_NOTE_ON or
    //         event.*.type == c.CLAP_EVENT_NOTE_OFF or
    //         event.*.type == c.CLAP_EVENT_NOTE_CHOKE
    //     ) {
    //         const note_event = @ptrCast([*c]const c.clap_event_note_t, @alignCast(@alignOf([*c]const c.clap_event_note_t), event));

    //         // If the event matches a voice, then it must be a note release
    //         var i: usize = 0;
    //         while(i < plugin.voices.items.len) : (i+=1) {
    //             var voice = &plugin.voices.items[i];

    //             if((note_event.*.key == -1 or voice.key == note_event.*.key)
    //             and (note_event.*.note_id == -1 or voice.note_id == note_event.*.note_id)
    //             and (note_event.*.channel == -1 or voice.channel == note_event.*.channel)
    //             ) {
    //                 if(event.*.type == c.CLAP_EVENT_NOTE_CHOKE) {
    //                     _ = plugin.voices.swapRemove(i);
    //                     if(i != 0) i -= 1;
    //                 } else {
    //                     voice.held = false;
    //                 }
    //             }
    //         }


    //         // If this is a note on event, create a new voice
    //         if(event.*.type == c.CLAP_EVENT_NOTE_ON) {
    //             const voice = Voice {
    //                 .held = true,
    //                 .note_id = note_event.*.note_id,
    //                 .channel = note_event.*.channel,
    //                 .key = note_event.*.key,
    //                 .phase = 0.0,
    //             };

    //             plugin.voices.append(voice) catch unreachable;
    //         }
    //     }
    // }
    }
}

pub fn render_audio(plugin: *Plugin, start: u32, end: u32,
    inputL: [*c]f32,
    inputR: [*c]f32,
    outputL: [*c]f32,
    outputR: [*c]f32
) void {
    var index: usize = start;
    while(index < end) : (index += 1) {
        var inL: f32 = inputL[index];
        var inR: f32 = inputR[index];
        const gain = plugin.params[@enumToInt(P.Gain)];
        const output_gain = plugin.params[@enumToInt(P.OutputGain)];

        var distortionL : f32 = ef.cub_nonl_distortion(inL, gain, 0.0) * output_gain;
        var distortionR : f32 = ef.cub_nonl_distortion(inR, gain, 0.0) * output_gain;

        var outL: f32 = 0;
        var outR: f32 = 0;
        for(plugin.filters.items) |*filter| {
            outL = filter.process(distortionL);
            outR = filter.process(distortionR);
        }

        outputL[index] = outL;
        outputR[index] = outR;
    }
}

// c api

// Extension for midi ports
const ExtensionNotePorts = struct {
    const extension = c.clap_plugin_note_ports_t {
        .count = count,
        .get = get,
    };

    fn count(_: [*c]const c.clap_plugin_t, is_input: bool) callconv(.C) u32 {
        _ = is_input;
        // if(is_input) return 1;
        return 0;
    }

    fn get(_: [*c]const c.clap_plugin_t, index: u32, is_input: bool, info: [*c]c.clap_note_port_info_t) callconv(.C) bool {
        _ = index;
        _ = is_input;
        _ = info;
        return false;
        // if(!is_input or index != 0) return false;
        // info.*.id = 0;
        // info.*.supported_dialects = c.CLAP_NOTE_DIALECT_CLAP;
        // info.*.preferred_dialect = c.CLAP_NOTE_DIALECT_CLAP;
        // std.log.info("{s}", .{std.fmt.bufPrintZ(info.*.name[0..], "Note Port", .{}) catch unreachable});
        // return true;
    }
};

// Audio ports
const ExtensionAudioPorts = struct {
    const extension = c.clap_plugin_audio_ports_t {
        .count = count,
        .get = get,
    };

    fn count(_: [*c]const c.clap_plugin_t, is_input: bool) callconv(.C) u32 {
        if(is_input) return 1;
        return 1;
    }

    fn get(_: [*c]const c.clap_plugin_t, index: u32, is_input: bool, info: [*c]c.clap_audio_port_info_t) callconv(.C) bool {
        if(index != 0) return false;
        if(is_input) {
            info.*.id = 0;
            info.*.channel_count = 2;
            info.*.flags = c.CLAP_AUDIO_PORT_IS_MAIN;
            info.*.port_type = &c.CLAP_PORT_STEREO;
            info.*.in_place_pair = c.CLAP_INVALID_ID;
            _ = std.fmt.bufPrintZ(info.*.name[0..], "Audio Input", .{}) catch unreachable;
            return true;
        }
        else {
            info.*.id = 1;
            info.*.channel_count = 2;
            info.*.flags = c.CLAP_AUDIO_PORT_IS_MAIN;
            info.*.port_type = &c.CLAP_PORT_STEREO;
            info.*.in_place_pair = c.CLAP_INVALID_ID;
            _ = std.fmt.bufPrintZ(info.*.name[0..], "Audio Output", .{}) catch unreachable;
            return true;
        }
    }
};

// Parameters extension
//
// This tells the host about the properties of our parameters
// (.count, .get_info), gives it a way to query the current
// value of parameters (.get_value), gives it a way to
// transform values to and from text (.value_to_text,
// .text_to_value), and also provides a mechanism for
// parameter synchronization when the plugin isn't processing
// audio (.flush). (https://nakst.gitlab.io/tutorial/clap-part-2.html)
// 
const ExtensionParams = struct {
    const extension = c.clap_plugin_params {
        .count = count,
        .get_info = get_info,
        .get_value = get_value,
        .value_to_text = value_to_text,
        .text_to_value = text_to_value,
        .flush = flush,
    };

    fn count(_: [*c] const c.clap_plugin_t)
    callconv(.C) u32 {
        return num_params();
    }

    fn get_info(_plugin: [*c] const c.clap_plugin_t, index: u32, info: [*c] c.clap_param_info)
    callconv(.C) bool {
        _ = _plugin;
        if(index == @enumToInt(P.Gain)) {
            info.* = std.mem.zeroes(c.clap_param_info);
            info.*.id = index;
            info.*.flags = c.CLAP_PARAM_IS_AUTOMATABLE | c.CLAP_PARAM_IS_MODULATABLE;
            info.*.min_value = 0.0;
            info.*.max_value = 1.0;
            info.*.default_value = 0.5;
            _ = std.fmt.bufPrintZ(info.*.name[0..], "Gain", .{}) catch unreachable;
            return true;
        }

        if(index == @enumToInt(P.OutputGain)) {
            info.* = std.mem.zeroes(c.clap_param_info);
            info.*.id = index;
            info.*.flags = c.CLAP_PARAM_IS_AUTOMATABLE | c.CLAP_PARAM_IS_MODULATABLE;
            info.*.min_value = 0.0;
            info.*.max_value = 1.0;
            info.*.default_value = 0.2;
            _ = std.fmt.bufPrintZ(info.*.name[0..], "Output Gain", .{}) catch unreachable;
            return true;
        }

        return false;
    }

    fn get_value(_plugin: [*c]const c.clap_plugin_t, id: c.clap_id, value: [*c] f64)
    callconv(.C) bool {
        var plugin = ptr_as(*Plugin, _plugin.*.plugin_data);
        var i = @intCast(u32, id);
        if (i >= num_params()) return false;
        
        plugin.mut.lock();
        defer plugin.mut.unlock();

        var val: f64 = 0;
        if(plugin.main_changed[i]) {
            val = plugin.main_params[i];
        } else {
            val = plugin.params[i];
        }
        value.* = val;
        return true;
    }

    fn value_to_text(_plugin: [*c]const c.clap_plugin_t, id: c.clap_id, value: f64, display: [*c]u8, size: u32)
    callconv(.C) bool {
        _ = _plugin;
        var i = @intCast(u32, id);
        if(i >= num_params()) return false;

        _ = std.fmt.bufPrintZ(display[0..size], "{d:.2}", .{value}) catch unreachable;
        return true;
    }

    fn text_to_value(_plugin: [*c]const c.clap_plugin_t, id: c.clap_id, display: [*c]const u8, value: [*c] f64)
    callconv(.C) bool {
        _ = _plugin; _ = id; _ = display; _ = value;
        return false;
    }

    fn flush(_plugin: [*c] const c.clap_plugin_t, ev_in: [*c] const c.clap_input_events_t, ev_out: [*c]const c.clap_output_events_t)
    callconv(.C) void {
        var plugin = ptr_as(*Plugin, _plugin.*.plugin_data);
        const ev_count = ev_in.*.size.?(ev_in);
        plugin.sync_main_to_audio(ev_out);

        var i: u32 = 0;
        while(i < ev_count) : (i += 1) {
            plugin.process_event(ev_in.*.get.?(ev_in, i));
        }
    }
};

const ExtensionState = struct {
    const extension = c.clap_plugin_state_t {
        .save = save,
        .load = load,
    };

    fn save(_plugin: [*c]const c.clap_plugin, stream: [*c]const c.clap_ostream)
    callconv(.C) bool {
        var plugin = ptr_as(*Plugin, _plugin.*.plugin_data);

        var ok = plugin.sync_audio_to_main();
        if(!ok) {
            std.log.err("Failed to sync audio to main!!!", .{});
        }

        const size = @sizeOf(f32) * num_params();
        var write_size: i64 = 0;
        while(size != write_size) { // if write_size is 0, then error
            const nbytes = stream.*.write.?(stream, as_void(&plugin.main_params), size);
            if(nbytes == 0) {
                break;
            }
            write_size += nbytes;
        }
        ok = ok or size == write_size;

        return ok;
    }

    fn load(_plugin: [*c]const c.clap_plugin, stream: [*c]const c.clap_istream)
    callconv(.C) bool {
        var plugin = ptr_as(*Plugin, _plugin.*.plugin_data);

        plugin.mut.lock();
            const size = @sizeOf(f32) * num_params();
            var read_size = stream.*.read.?(stream, as_void(&plugin.main_params), size);
            while(size != read_size and read_size <= 0) { // if read_size is 0, then error
                const nbytes = stream.*.read.?(stream, as_void(&plugin.main_params), size);
                if(nbytes == 0) {
                    break;
                }

                read_size += nbytes;
            }
        plugin.mut.unlock();

        return size == read_size;
    }
};

/// Plugin Class, defines the actual plugin event functions for the host
/// to call.
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
    var plugin = ptr_as(*Plugin, _plugin.*.plugin_data);
    // plugin.voices = std.ArrayList(Voice).init(c_allocator);
    plugin.mut = .{};

    var i: u32 = 0;
    while(i < num_params()) : (i += 1) {
        var info = std.mem.zeroes(c.clap_param_info_t);
        _ = ExtensionParams.extension.get_info.?(_plugin, i, @ptrCast([*c] c.clap_param_info_t, &info));
        plugin.params[i] = @floatCast(f32, info.default_value);
        plugin.main_params[i] = @floatCast(f32, info.default_value);
    }
    return true;
}


fn destroy_plugin(_plugin: [*c]const c.clap_plugin_t)
callconv(.C) void {
    var plugin = ptr_as(*Plugin, _plugin.*.plugin_data);
    c_allocator.destroy(plugin);
}

fn activate_plugin(_plugin: [*c]const c.clap_plugin_t, sample_rate: f64, min_frames_count: u32, max_frames_count: u32)
callconv(.C) bool {
    _ = min_frames_count; _ = max_frames_count;
    var plugin = ptr_as(*Plugin, _plugin.*.plugin_data);
    plugin.sample_rate = sample_rate;
    plugin.filters = std.ArrayList(ef.biquad_d2).init(c_allocator);
    plugin.filters.append(ef.biquad_d2.apply_peak_eq_filter(plugin.sample_rate, 1000, 2.0, 1.0)) catch unreachable;
    return true;
}

fn deactivate_plugin(_plugin: [*c]const c.clap_plugin_t)
callconv(.C) void {
    var plugin = ptr_as(*Plugin, _plugin.*.plugin_data);
    plugin.filters.deinit();
}

fn start_processing(_plugin: [*c]const c.clap_plugin_t)
callconv(.C) bool {
    var plugin = ptr_as(*Plugin, _plugin.*.plugin_data);
    _ = plugin;
    return true;
}

fn stop_processing(_plugin: [*c]const c.clap_plugin_t)
callconv(.C) void {
    var plugin = ptr_as(*Plugin, _plugin.*.plugin_data);
    _ = plugin;
}

fn reset(_plugin: [*c]const c.clap_plugin_t)
callconv(.C) void {
    var plugin = ptr_as(*Plugin, _plugin.*.plugin_data);
    _ = plugin;
}

fn process(_plugin: [*c]const c.clap_plugin_t, _process: [*c]const c.clap_process)
callconv(.C) c.clap_process_status {
    var plugin = ptr_as(*Plugin, _plugin.*.plugin_data);

    plugin.sync_main_to_audio(_process.*.out_events);

    std.testing.expect(_process.*.audio_outputs_count == 1) catch unreachable;
    std.testing.expect(_process.*.audio_inputs_count == 1) catch unreachable;

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

        plugin.render_audio(i, next_event_frame,
            _process.*.audio_inputs[0].data32[0], _process.*.audio_inputs[0].data32[1],
            _process.*.audio_outputs[0].data32[0], _process.*.audio_outputs[0].data32[1]);
        i = next_event_frame;
    }

    return c.CLAP_PROCESS_CONTINUE;
}

fn get_extension(_plugin: [*c]const c.clap_plugin_t, id: [*c]const u8)
callconv(.C) ?*const anyopaque{
    var plugin = ptr_as(*Plugin, _plugin.*.plugin_data);
    _ = plugin;
    if(std.mem.eql(u8, span(id), c.CLAP_EXT_NOTE_PORTS[0..])) {
        return as_const_void(&ExtensionNotePorts.extension);
    }
    if(std.mem.eql(u8, span(id), c.CLAP_EXT_AUDIO_PORTS[0..])) {
        return as_const_void(&ExtensionAudioPorts.extension);
    }

    if(std.mem.eql(u8, span(id), c.CLAP_EXT_PARAMS[0..])) {
        return as_const_void(&ExtensionParams.extension);
    }
    if(std.mem.eql(u8, span(id), c.CLAP_EXT_STATE[0..])) {
        return as_const_void(&ExtensionState.extension);
    }

    return null;
}

fn on_main_thread(_plugin: [*c]const c.clap_plugin_t)
callconv(.C) void {
    var plugin = ptr_as(*Plugin, _plugin.*.plugin_data);
    _ = plugin;
}

// I hate dealing with c style type erasure in zig, so these
// make the process a bit more concise
fn as_void(ptr: anytype) ?*anyopaque {
    return @ptrCast(?*anyopaque, ptr);
}

fn as_const_void(ptr: anytype) ?*const anyopaque {
    return @ptrCast(?*const anyopaque, ptr);
}

fn ptr_as(comptime T: anytype, ptr: anytype) T {
    return @ptrCast(T, @alignCast(@alignOf(T), ptr));
}
