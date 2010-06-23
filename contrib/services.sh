#!/bin/sh
 
#
# $Id: services.sh,v 4.0 2004/11/16 20:57:30 matt Exp $
#

PATH=/usr/local/bin:/usr/sbin:/usr/bin:/bin
export PATH
 
if [ -d /var/service ]
then
	SVCDIR=/var/service
else
	if [ -d /service ]
	then
		SVCDIR=/service
	else
		echo "Can't find your service directory!\n";
		SVCDIR=""
	fi
fi

case "$1" in
start)
	if [ ! -f /var/run/svscan.pid ]
	then
		echo -n "Starting services: svscan"

		cd $SVCDIR
		env - PATH="$PATH" svscan &
		echo $! > /var/run/svscan.pid
		for dir in `ls $SVCDIR`
		do
			echo -n " $dir"
		done
		echo "."
	else
		echo "It appears svscan is already running. NOT starting!"
	fi
	;;
restart)
	echo -n "Restarting services: "
	for dir in `ls $SVCDIR`
	do
		echo -n " $dir"
	done
	svc -t $SVCDIR/*
	svc -t $SVCDIR/*/log
	echo "."
	;;
stop)
	echo -n "Stopping services: svscan"
	kill `cat /var/run/svscan.pid`
	rm /var/run/svscan.pid
	for dir in `ls $SVCDIR`
	do
		echo -n " $dir"
	done
	svc -dx $SVCDIR/*
	svc -dx $SVCDIR/*/log
	echo "."
	;;
*)
	echo "Usage $0 { start | restart | stop }"
	;;
esac
