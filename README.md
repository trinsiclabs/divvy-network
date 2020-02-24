# Divvy network

The network component is a
[Hyperledger Fabric](https://www.hyperledger.org/projects/fabric) network and
is the core component of the Divvy platform.

## Getting started

Normally the [application](https://github.com/flashbackzoo/divvy-application)
and [API](https://github.com/flashbackzoo/divvy-application) components are
used to interface with the network but it is also possible to run the network
in "headless" mode, for development.

If you just want run the platform and have a poke around, check out the main
[platform documentation](https://github.com/flashbackzoo/divvy).

If you're developing / debugging the network component specifically, read on.

### Running the network in headless mode

Make sure you have set up the host VM as described in the
[platform docs](https://github.com/flashbackzoo/divvy).

Login to the host VM and bring up the network:

```
$ vagrant ssh
$ cd network
$ ./network.sh up
```

This brings up the base network consisting of a solo order, CA, and CLI
container. Logging information is streamed to this window, so keep it
open, and use a new window for the next steps.

### Populate the network

In your new terminal window add a couple of organisations to the network.
This is done from the `web.app.divvy.com` container to simulate a request
from the application.

```
$ sudo docker exec -it web.app.divvy.com bash
```

Create the first organisation:

```
$ echo "./organisation.sh create --org org1 --pport 8051 --ccport 8052 --caport 8053" > host_queue
```

Create the second organisation:

```
$ echo "./organisation.sh create --org org2 --pport 9051 --ccport 9052 --caport 9053" > host_queue
```

Note the application doesn't know about these organisations, so they are only useful
for network development purposes. Accounts have not been created in the
client application database.

### Join a channel

While in the application container, join org2 to the org1 channel:

```
$ echo "./organisation.sh joinchannel --org org2 --channelowner org1" > host_queue
```

Now exit the application container:

```
$ exit
```

### Make a trade

Log into the org1 cli container:

```
$ sudo docker exec -it cli.org1.divvy.com bash
```

See the current height and hash of the org1 blockchain:

```
$ peer channel getinfo -c org1-channel
```

Transfer ownership of a share from org1 to org2:

```
$ peer chaincode invoke -C org1-channel -n share -c '{"Args":["com.divvy.share:changeShareOwner","org1","1","org1","org2"]}' --tls --cafile /opt/gopath/src/github.com/hyperledger/fabric/orderer/msp/tlscacerts/tlsca.divvy.com-cert.pem
```

See the new height and hash of the org1 blockchain:

```
$ peer channel getinfo -c org1-channel
```

Verify the share has changed ownership:

```
$ peer chaincode query -C org1-channel -n share -c '{"Args":["com.divvy.share:queryShare","org1","1"]}'
```

## Scripts

The two scripts used to manage the network are `network.sh` and
`organisation.sh`. They both have help commands `--help` and the scripts
themselves are worth having a read through.
