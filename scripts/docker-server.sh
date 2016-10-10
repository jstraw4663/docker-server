#!/bin/bash

# Check if running as root

	if [ "$(id -u)" != "0" ]; then
   		echo "This script must be run as root" 1>&2
   		exit 1
	fi

# Functions

function _installdocker() {
    curl -sSL https://get.docker.com/ | sh
}

function _createcontainers() {

    # Plex
	docker pull linuxserver/plex
        docker create \
        --name=plex \
        --net=host \
        -e VERSION=latest \
        -e PUID=$uid -e PGID=$gid \
        -e TZ=$timezone \
        -v $config/plex:/config \
        -v $media:/data \
        linuxserver/plex
	docker start plex

    # CouchPotato
	docker pull linuxserver/couchpotato
        docker create \
        --name=couchpotato \
        -v $config/couchpotato:/config \
        -v $downloads:/downloads \
        -v $media/Movies:/movies \
        -e PGID=$gid -e PUID=$uid  \
        -e TZ=$timezone \
        -p 5050:5050 \
        linuxserver/couchpotato
	docker start couchpotato

    # Sonarr
	docker pull linuxserver/sonarr
        docker create \
        --name sonarr \
        -p 8989:8989 \
        -e PUID=$uid -e PGID=$gid \
        -v /dev/rtc:/dev/rtc:ro \
        -v $config/sonarr:/config \
        -v $media/TV\ Shows:/tv \
        -v $downloads:/downloads \
        linuxserver/sonarr
	docker start sonarr

    # PlexPy
	docker pull linuxserver/plexpy
        docker create \
        --name=plexpy \
        -v $config/plexpy:/config \
        -v $config/plex/Library/Application\ Support/Plex\ Media\ Server/Logs:/logs:ro \
        -e PGID=$gid -e PUID=$uid  \
        -e TZ=$timezone \
        -p 8181:8181 \
        linuxserver/plexpy
	docker start plexpy

    # SABnzbd
	docker pull linuxserver/sabnzbd
        docker create \
        --name=sabnzbd \
        -v $config/sabnzbd:/config \
        -v $downloads/Usenet:/downloads \
        -v $downloads/Usenet/incomplete:/incomplete-downloads \
        -e PGID=$gid -e PUID=$uid \
        -e TZ=$timezone \
        -p 8080:8080 -p 9090:9090 \
        linuxserver/sabnzbd
	docker start sabnzbd

    # Deluge
	docker pull linuxserver/deluge
        docker create \
        --name deluge \
        --net=host \
        -e PUID=$uid -e PGID=$gid \
        -e TZ=$timezone \
        -v $downloads/Torrents:/downloads \
        -v $config/deluge:/config \
        linuxserver/deluge
	docker start deluge

    # Jackett
	docker pull linuxserver/jackett
        docker create \
        --name=jackett \
        -v $config/jackett:/config \
        -v $downloads/Torrents/watch:/downloads \
        -e PGID=$gid -e PUID=$uid \
        -e TZ=$timezone \
        -p 9117:9117 \
        linuxserver/jackett
	docker start jackett

    # PlexRequests
	docker pull linuxserver/plexrequests
        docker create \
        --name=plexrequests \
        -v /etc/localtime:/etc/localtime:ro \
        -v $config/plexrequests:/config \
        -e PGID=$gid -e PUID=$uid  \
        -e URL_BASE=/requests \
        -p 3000:3000 \
        linuxserver/plexrequests
	docker start plexrequests

    # Nginx
	docker pull linuxserver/nginx
        docker create \
        --name=nginx \
        -v /etc/localtime:/etc/localtime:ro \
        -v $config/nginx:/config \
        -e PGID=$gid -e PUID=$uid  \
        -p 80:80 -p 443:443 \
        linuxserver/nginx
	docker start nginx

    # CrashPlan
	docker pull jrcs/crashplan
        docker run -d \
        --name crashplan \
        -h $HOSTNAME \
        -e TZ=$timezone \
        -p 4242:4242 -p 4243:4243 \
        -v $config/crashplan:/var/crashplan \
        -v $media:/media \
        -v $config:/docker \
        jrcs/crashplan:latest
	docker start crashplan

    sleep 60 # wait for containers to start

    for d in $config/* ; do
	dir=$(basename $d)
	cat > /etc/systemd/system/$dir.service << EOF
	[Unit]
	Description=$dir container
	Requires=docker.service
	After=docker.service

	[Service]
	Restart=always
	ExecStart=/usr/bin/docker start -a $dir
	ExecStop=/usr/bin/docker stop -t 2 $dir

	[Install]
	WantedBy=default.target
	EOF
	systemctl daemon-reload
	systemctl enable $dir
EOF
    done
}

function _reverseproxy() {

	docker stop couchpotato jackett plexpy sonarr
	sed -i 's#url_base =#url_base = /couchpotato#' /opt/docker/couchpotato/config.ini
	sed -i 's#"BasePathOverride": null#"BasePathOverride": "/jackett"#' /opt/docker/jackett/Jackett/ServerConfig.json
	sed -i 's#http_root = ""#http_root = /plexpy#' /opt/docker/plexpy/config.ini
	sed -i 's#<UrlBase></UrlBase>#<UrlBase>/sonarr</UrlBase>#' /opt/docker/sonarr/config.xml
	docker start couchpotato jackett plexpy sonarr

}

function _nginx() {

	apt-get update
	apt-get upgrade -y
	docker stop nginx
        rm $config/nginx/nginx/site-confs/default
	ip=$(wget -qO- http://ipecho.net/plain)
	cat > $config/nginx/nginx/site-confs/default << EOF
		server {
			listen 80 default_server;
			server_name $domain www.$domain;
			return 301 https://\$server_name\$request_uri;
			}


		server {
			listen 443 default_server;
			server_name $domain www.$domain;
			ssl on;
			ssl_certificate /config/keys/bergplex.crt;
			ssl_certificate_key /config/keys/bergplex.key;

			auth_basic "Restricted";
			auth_basic_user_file /config/.htpasswd;

			location /sonarr {
				proxy_pass http://$ip:8989;
				proxy_set_header Host \$host;
				proxy_set_header X-Real-IP \$remote_addr;
				proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
				}

			location /deluge {
				proxy_pass http://$ip:8112/;
				proxy_set_header X-Deluge-Base "/deluge/";
				proxy_set_header Host \$host;
				proxy_set_header X-Real-IP \$remote_addr;
				proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
				}

			location /requests {
				auth_basic off;
				proxy_pass http://$ip:3000;
				proxy_set_header Host \$host;
				proxy_set_header X-Real-IP \$remote_addr;
				proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
				}

			location /sabnzbd {
				proxy_pass http://$ip:8080;
				proxy_set_header Host \$host;
				proxy_set_header X-Real-IP \$remote_addr;
				proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
				}

			location /couchpotato {
				proxy_pass http://$ip:5050;
				proxy_set_header Host \$host;
				proxy_set_header X-Real-IP \$remote_addr;
				proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
				}

			location /plexpy {
				proxy_pass http://$ip:8181;
				proxy_set_header Host \$host;
				proxy_set_header X-Real-IP \$remote_addr;
				proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
				}

			location /jackett/ {
				proxy_pass http://$ip:9117/;
				proxy_set_header Host \$host;
				proxy_set_header X-Real-IP \$remote_addr;
				proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
				}

			}
EOF

	chown $user:$user $config/nginx/nginx/site-confs/default
        apt-get install -y apache2-utils
	htpasswd -b -c $config/nginx/.htpasswd $user $password
        cp ../ssl/bergplex.* $config/nginx/keys
        docker start nginx

}

spinner() {
    local pid=$1
    local delay=0.25
    local spinstr='|/-\'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf " [${bold}${yellow}%c${normal}]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
    echo -ne "${OK}"
}

OK=$(echo -e "[ ${bold}${green}DONE${normal} ]")
echo
echo -n "##### DOCKER-SERVER #####";echo
echo
read -p "User for containers and basic authentication?  " user
while true
do
    echo
    read -s -p "Create password " password
    echo
    read -s -p "Verify password " password2
    echo
    [ "$password" = "$password2" ] && break
    echo "Please try again"
done
echo
echo -n "What is your domain name? "; read domain
echo
echo -n "What is the path to docker container config files? (do not include trailing /) "; read config
echo
echo -n "What is the path to media files? (do not include trailing /) "; read media
echo
echo -n "What is the path to downloads? (do not include trailing /) "; read downloads
echo
echo -n "Installing docker ...";_installdocker >/dev/null 2>&1 & spinner $!;echo
usermod -aG docker $user
uid=$(id -u $user)
gid=$(id -g $user)
timezone=$(cat /etc/timezone)
echo
echo -n "Creating docker containers ...";_createcontainers >/dev/null 2>&1 & spinner $!;echo
echo
echo -n "Applying reverse proxy settings to containers ...";_reverseproxy >/dev/null 2>&1 & spinner $!;echo
echo
echo -n "Setting up nginx with basic authentication and SSL certificate ...";_nginx >/dev/null 2>&1 & spinner $!;echo
echo
echo -n "Setting permissions ..."; chown -R $user:$user $config $media $downloads & spinner $!;echo
echo
echo -n "Setup complete.";echo
echo
echo -n "Replace contents of CrashPlan .ui_info on local system with:";echo
echo
echo $(cat $config/crashplan/id/.ui_info) > /home/$user/temp.txt
sed -i "s/0.0.0.0/$domain/" /home/$user/temp.txt
cat /home/$user/temp.txt
rm /home/$user/temp.txt
echo
echo -n "Enjoy!";echo
echo
echo -n "System will reboot in 30 seconds ...";echo
echo
sleep 30
reboot -h now