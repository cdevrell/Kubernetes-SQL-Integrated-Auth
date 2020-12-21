#!/bin/sh

## All echo outputs are viewable via kubectl logs <podname> <conatinername>

## Output the username.
echo "The principal is $USER"

## Create keytab file.
ktutil -k /krb5/$USER.keytab add -p $USER -w $PASSWORD -e RC4-HMAC -V 1

## Check if keytab file creation was successful.
if [ -e /krb5/$USER.keytab ]
then
    echo "*** using $USER keytab ***"

    ## Start an endless loop.
    while true
    do
        ## Authenticate using the keytab and store the token response in /dev/shm/ccache.
        kinit -k -t /krb5/$USER.keytab -c /dev/shm/ccache $USER
        ## Output a list of generated tokens for debugging pursposes.
        klist -c /dev/shm/ccache

        ## Wait 1 hour before reauthenticating.
        echo "*** Waiting for 1 hour ***"
        sleep 3600
    done
else
    ##  Keytab file was not found so output error and exit container.
    echo "Keytab for principal $USER not found."
fi