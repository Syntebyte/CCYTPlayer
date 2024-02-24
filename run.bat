@echo off

python -m venv venv
call venv\Scripts\activate.bat

pip install flask
pip install youtube-search-python
pip install pytube
pip install moviepy
pip install pydub

python server.py
pause