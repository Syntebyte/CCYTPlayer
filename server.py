from flask import Flask, request, send_file, stream_with_context, Response
from youtubesearchpython import SearchMode, VideoDurationFilter, CustomSearch as cs
from pytube import YouTube
from moviepy.editor import AudioFileClip
from pydub import AudioSegment
import os
#import random
#import time
#import subprocess
from hashlib import sha256

folder = os.getcwd() + '/download'
config = os.getcwd() + '/server.cfg'

ip = '0.0.0.0'

if os.path.exists(config):
    f = open(config, 'r')
    ip = f.read().strip()
    f.close()
else:
    f = open(config, 'w')
    f.write(ip)
    f.close()

def hs(inp):
    return sha256(inp.encode('utf-8')).hexdigest()

app = Flask(__name__)
@app.route('/')
def index():

    value = request.args.get('v', '').strip().replace('_', ' ')
    if not value:
        return send_file('setup.lua')

    search = cs(value, VideoDurationFilter.short, limit=1)
    if not search:
        return 'videonotfound', 400

    video = search.result()['result'][0]['link'];
    h = os.path.join(folder, hs(video) + '.wav')
    print('"' + value + '" saved as ' + h)

    if not os.path.isfile(h):
        YouTube(video).streams.filter(only_audio=True, file_extension='mp4').first().download(output_path=folder, filename=h + '.mp4')
        audio = AudioFileClip(h + '.mp4') #VideoFileClip for mp4 with frames
        #audio = video.audio
        audio.write_audiofile(h, ffmpeg_params=['-ac', '1', '-acodec', 'pcm_u8', '-ar', '48000', '-b:a', '128k'])
        #subprocess.run(['ffmpeg', '-i', realm, '-ar', '48000', '-acodec', 'pcm_u8', '-ac', '1', realw])
        os.remove(h + '.mp4')
    return send_file(h)

if __name__ == '__main__':
    os.environ['FLASK_RUN_PORT'] = '25558'  # Set the port to 80, by default it is 5000
    os.environ['FLASK_ENV'] = 'development'
    app.run(host=ip, port=25558)