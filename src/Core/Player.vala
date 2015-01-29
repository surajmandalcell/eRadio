/*-
 *  Copyright (c) 2014 George Sofianos
 *
 *  This program is free software: you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation, either version 3 of the License, or
 *  (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 *  Authored by: George Sofianos <georgesofianosgr@gmail.com>
 *               Fotini Skoti <fotini.skoti@gmail.com>
 */

using Gst;

// TODO refactor
public class Radio.Core.Player : GLib.Object {

    private Gst.Pipeline pipeline;
    private Gst.Element  source;
    private Gst.Element  converter;
    private Gst.Element  sink;
    private Gst.Bus bus;

    public bool has_url {get;set;}
    public PLAYER_STATUS status;
    public Models.Station? station;

    public signal void volume_changed (double volume_value);
    public signal void play_status_changed(PLAYER_STATUS status);
    public signal void playback_error(GLib.Error error);

    public Player () {
        status = PLAYER_STATUS.STOPPED;

        // Create GStreamer Elements
        create_gstreamer_elements ();
        link_gstreamer_elements ();


        // Connect internal signals
        connect_handlers_to_internal_signals ();
        
    }

    // TODO throws critical error
    private void create_gstreamer_elements () {
        pipeline  = new Gst.Pipeline ("main-pipeline");
        source    = Gst.ElementFactory.make ("uridecodebin","source");
        converter = Gst.ElementFactory.make ("audioconvert","converter");
        sink      = Gst.ElementFactory.make ("autoaudiosink","sink");
        bus       = pipeline.get_bus();
    }

    // TODO throws critical error
    private void link_gstreamer_elements () {
        pipeline.add_many (source,converter,sink);

        if (!converter.link (sink))
            stdout.printf ("Error While linking convert with sink\n");
    }

    private void connect_handlers_to_internal_signals () {
        source.pad_added.connect (handle_url_decoded);
        bus.add_watch (Priority.DEFAULT,handle_bus_has_message);
    }

    private void handle_url_decoded (Gst.Element element, Gst.Pad pad) {
        stdout.printf("- Padd Added\n");
        // Here we can check the type of the media TODO
        //if (!waiting_uri_decode)
            //return;

        //waiting_uri_decode = false;

        if (pad.get_current_caps ().is_fixed ())
            stdout.printf("- Caps is fixed\n");
        else 
            stdout.printf ("- Caps is not fixed \n");

        //stdout.printf(pad.get_current_caps ().to_string () + "\n");
        var struct_string = pad.get_current_caps ().to_string ();

        if (struct_string.has_prefix ("audio"))
            pad.link (converter.get_static_pad ("sink"));
        else
            stdout.printf ("- Stream is not an audio\n");
    }

    private bool handle_bus_has_message (Gst.Bus bus, Gst.Message message) {
        switch(message.type) {

            case Gst.MessageType.ERROR:
                GLib.Error error;
                string debug;
                message.parse_error(out error,out debug);

                if(error.message != "Cancelled") {
                    stdout.printf("Error Occurred %s \n",error.message);
                    pipeline.set_state(State.NULL);
                    playback_error(error);
                    this.has_url = false;
                }

                break;

            case Gst.MessageType.EOS:
                stdout.printf ("DEBUG::End Of Stream Reached\n");
                pipeline.set_state(State.NULL);
                break;
        }
        return true;
    }


    public void add (Radio.Models.Station station) throws Radio.Error{

        string uri = station.url;
        string final_uri = station.url;
        string content_type = "";

        this.station = station;

        if (final_uri.index_of("http") == 0){
            content_type = this.get_content_type (uri);
        }

        // Check content type to decode
        if ( content_type == "audio/x-mpegurl" || content_type == "audio/mpegurl" ) {
            var list = M3UDecoder.parse (uri);
            // Temporary ignoring all links beside the first
            if ( list != null )
                final_uri = list[0];
            else
                throw new Radio.Error.GENERAL ("Could not decode m3u file, wrong url or corrupted file");
        }
        else if ( content_type == "audio/x-scpls" || content_type == "application/pls+xml") {
            var list = PLSDecoder.parse (uri);
            // Temporary ignoring all links beside the first
            if ( list != null )
                final_uri = list[0];
            else
                throw new Radio.Error.GENERAL ("Could not decode pls file, wrong url or corrupted file");

        }
        else if ( content_type == "video/x-ms-wmv" || content_type == "video/x-ms-wvx" || content_type == "video/x-ms-asf" || content_type == "video/x-ms-asx" || content_type == "audio/x-ms-wax" || uri.last_index_of (".asx",uri.length - 4) != -1) {
            var list = ASXDecoder.parse (uri);
            // Temporary ignoring all links beside the first
            if ( list != null )
                final_uri = list[0];
            else
                throw new Radio.Error.GENERAL ("Could not decode asx file, wrong url or corrupted file");
        }

        this.has_url = true;

        pipeline.set_state (State.READY);
        source.set ("uri",final_uri);
    }

    public void set_volume (double value) {
        pipeline.set_property ("volume",value);
        volume_changed (value);
    }

    public double get_volume () {
        var val = pipeline.get_property ("volume");
        return (double)val;
    }

    public void play() {
        if(pipeline != null) {
            pipeline.set_state(State.PLAYING);
            status = PLAYER_STATUS.PLAYING;
            play_status_changed(PLAYER_STATUS.PLAYING);
        }
    }

    public void pause() {
        if(pipeline != null) {
            pipeline.set_state(State.PAUSED);
            status = PLAYER_STATUS.PAUSED;
            play_status_changed(PLAYER_STATUS.PAUSED);
        }

    }

    public void stop() {
        if(pipeline != null) {
            pipeline.set_state(State.NULL);
            status = PLAYER_STATUS.STOPPED;
            play_status_changed(PLAYER_STATUS.STOPPED);
            this.has_url = false;
            station = null;
        }
    }
    

    // Do we really need content type ? Check if pad_added reports the same content
    private string? get_content_type (string url) {

        Soup.SessionSync session = new Soup.SessionSync ();
        session.timeout = 2;
        Soup.Message msg = new Soup.Message ("GET", url);

        string content_type = "";
        msg.got_headers.connect( ()=>{

            content_type = msg.response_headers.get_content_type (null);
            session.cancel_message (msg,Soup.Status.CANCELLED);
        });

        session.send_message (msg);

        // Note: status code returns 1, possibly because we cancel request, so we check length
        if (content_type.length == 0) {
            stderr.printf("Could not get content type\n");
            return null;
        }

        return content_type;


    }
}