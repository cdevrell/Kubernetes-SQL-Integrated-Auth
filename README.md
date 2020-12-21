# Kerberos Sidecar

## Purpose
The purpose of this image is to provide a method of enabling .Net Core applications running within Linux containers which are not joined to the domain to use integrated SQL authentication through Kerberos.

## Usage
This image is designed to be run as a "sidecar" in a Kubernetes pod. This means that for each deployment of an app which requires integrated SQL authentication, this container will be deployed alongside it as a member of the same pod.

In order to use this image, the container must be deployed as part of the deployment spec along with the existing app. All volume mounts must also be mapped to allow sharing of the Kerberos token. See the "How it works" section before for more detail.

## Prerequisites
### Prerequisites for building a custom app
#### Packages
In order to deploy a custom app and use integrated security, the following packages must be installed as part of the image build process.

This is a snippet from a Debian based docker image. The exact command may vary depending on base image.
~~~
RUN apt-get update && apt-get install -y krb5-config krb5-user
~~~
#### Connection String
Within the connection string of the application, ensure `Integrated Security=SSPI;` is set.

### Prerequisites for SQL Server
#### Create an SPN.
Sometimes this is handled by SQL automatically but in the event of the SQL Server service running as a domain account which does not have write permissions to its own user in AD, run the following command to manually create a SPN for this user.

~~~
setspn -S MSSQLSvc/<FQDN of SQL Server Host> <sAMAccountName>
~~~

The SPN registers the SQL service running under that user with the directory and therefore enables SQL to authenticate over Kerberos rather than NTLM.

More information is available from Microsoft here: https://docs.microsoft.com/en-us/sql/database-engine/configure-windows/register-a-service-principal-name-for-kerberos-connections

To test if the SPN is configured successfully, use the Microsoft Kerberos Configuration Manager for SQL Server tool: https://www.microsoft.com/en-us/download/details.aspx?id=39046


## Example Usage
The following example shows a typical deployment using a *deployment* manifest, and 2 *configmap* manifests.

### Deployment.yaml
In this example, this deployment will deploy 1 pod with 2 containers: the original app which requires authenticated SQL access (named web-app), and the Kerberos sidecar. This deployment also sets resource limits and maps the volumes required for Kerberos to work.
~~~
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-app-deployment
  namespace: web-app
spec:
  selector:
    matchLabels:
      app: web-app
  template:
    metadata:
      labels:
        app: web-app
    spec:
      containers:
      - name: web-app
        image: ***IMAGE REPOSITORY***
        imagePullPolicy: Always
        resources:
          limits:
            memory: "128Mi"
            cpu: "300m"
        volumeMounts:
          - name: ccache
            mountPath: /dev/shm
          - name: krb5-config
            mountPath: /etc/krb5.conf
            subPath: krb5.conf
          - name: krb5-domain
            mountPath: /etc/krb5.conf.d
        ports:
          - containerPort: 80
            name: http
      - name: kerberos-sidecar
        image: cdevrell/kubernetes-sql-integrated-auth:latest
        imagePullPolicy: IfNotPresent
        env:
          - name: USER
            value: ***ENTER USERNAME HERE IN THE FORMAT <username>@<DOMAIN IN UPPERCASE>***
          - name: PASSWORD
            value: ***ENTER PASSWORD HERE***
        resources:
          limits:
            memory: "128Mi"
            cpu: "100m"
        volumeMounts:
          - name: keytabs
            mountPath: /krb5
          - name: ccache
            mountPath: /dev/shm
          - name: krb5-config
            mountPath: /etc/krb5.conf
            subPath: krb5.conf
          - name: krb5-domain
            mountPath: /etc/krb5.conf.d
      volumes:
        - name: keytabs
          emptyDir: {}
        - name: ccache
          emptyDir:
            medium: Memory
        - name: krb5-config
          configMap:
            defaultMode: 420
            name: krb5-config
        - name: krb5-domain
          configMap:
            defaultMode: 420
            name: krb5-domain
~~~

### configmap-krb5-conf.yaml
This configmap manifest creates the global settings config file for Kerberos within the container. It specifies the location of the domain specific files (/etc/krb5.conf.d/) and the default locations for the keytab and token cache.

In this example, the service is configured to look for the *username@EXAMPLE.COM.keytab* file by default as that is the user credentials being passed through in the deployment.

The ccache directory is a location in RAM which is mounted to both containers in the pod.

**Note: this file is case sensitive**
~~~
apiVersion: v1
kind: ConfigMap
metadata:
  name: krb5-config
  namespace: web-app
data:
  krb5.conf: |
    includedir /etc/krb5.conf.d/

    [logging]
    default = STDERR

    [libdefaults]
    default_ccache_name=FILE:/dev/shm/ccache
    default_keytab_name=/krb5/username@EXAMPLE.COM.keytab
    ignore_acceptor_hostname = true
    rdns = false
~~~

### configmap-krb5-domain.yaml
This configmap manifest creates the domain specific config file which provides information on the location of the DC/KDC (in this case *example.com*).

**Note: this file is case sensitive**
~~~
apiVersion: v1
kind: ConfigMap
metadata:
  name: krb5-domain
  namespace: web-app
data:
  example.com.conf: |
    [realms]
    EXAMPLE.COM = {
      kdc = example.com
      default_domain = example.com
    }
    
    [domain_realm]
    example.com = EXAMPLE.COM
~~~

## How it works
The Kerberos Sidecar container is responsible for all the authentication against the DC using the provided username and password. First, the Kerberos sidecar container will create an encrypted keytab file based on the username and password. This is then used to authenticate against the DC/KDC.
The container will then store the Kerberos authentication token in a pod-restricted location accessible to the app container running in the same pod.

Every 1 hour, the Kerberos Sidecar will reauthenticate against the DC and generate a new authentication token to ensure the authentication request does not expire.

The app will then look in this location for the Kerberos token and use this to authenticate against the SQL server.

The SQL server will query the DC using its SPN to verify its identity and grant access if authentication is successful.

![Process Diagram](https://raw.githubusercontent.com/cdevrell/Kubernetes-SQL-Integrated-Auth/master/resources/KubernetesKerberos.jpg)

## Credit
Credit to this blog which provided the base concept for this version to be adapted to work autonomously and outside of openshift.
https://www.openshift.com/blog/kerberos-sidecar-container
