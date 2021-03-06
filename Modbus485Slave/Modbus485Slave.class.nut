// Copyright (c) 2017 Electric Imp
// This file is licensed under the MIT License
// http://opensource.org/licenses/MIT

class Modbus485Slave extends ModbusSlave {
    static MIN_REQUEST_LENGTH = 4;
    _slaveID = null;
    _uart = null;
    _rts = null;
    _receiveBuffer = null;
    _shouldParseADU = null;
    _minInterval = null;

    //
    // Constructor for Modbus485Slave
    //
    // @param  {object} uart - The UART object
    // @param  {object} rts - The pin used as RTS
    // @param  {table} params - The table contains all the arugments the constructor expects
    // @item  {integer} baudRate - 19200 bit/sec by dafult
    // @item  {integer} dateBits - Word size , 8 bit by default
    // @item  {enum} parity - PARITY_NONE by default
    // @item  {integer} stopBits - 1 bit by default
    // @item  {bool} debug - false by default. If enabled, the outgoing and incoming ADU will be printed for debugging purpose
    //
    constructor(uart, rts, slaveID, params = {}) {
        if (!("CRC16" in getroottable())) {
            throw "Must include CRC16 library v1.0.0+";
        }
        if (!("ModbusSlave" in getroottable())) {
            throw "Must include ModbusSlave library v1.0.0+";
        }
        base.constructor(("debug" in params) ? params.debug : false);
        _uart = uart;
        _rts = rts;
        _slaveID = slaveID;
        _shouldParseADU = true;
        local baudRate = ("baudRate" in params) ? params.baudRate : 19200;
        local dataBits = ("dataBits" in params) ? params.dataBits : 8;
        local parity = ("parity" in params) ? params.parity : PARITY_NONE;
        local stopBits = ("stopBits" in params) ? params.stopBits : 1;
        _receiveBuffer = blob();
        // 4.5 characters time in microseconds
        _minInterval = 45000000.0 / baudRate;
        _uart.configure(baudRate, dataBits, parity, stopBits, TIMING_ENABLED, _onReceive.bindenv(this));
        _rts.configure(DIGITAL_OUT, 0);
    }

    //
    // set the slave ID
    //
    // @params {integer} slaveID  the slave id
    //
    function setSlaveID(slaveID) {
        if (typeof slaveID != "integer") {
            throw "Slave ID must be an integer";
        }
        _slaveID = slaveID;
    }

    //
    // the callback function for when it receives packets
    //
    function _onReceive() {
        local data = _uart.read();
        while (data != -1) {
            if (_receiveBuffer.len() > 0 || data != 0x00) {
                // the first 22 bits are the information about interval between each character
                local interval = data >> 8;
                if (interval > _minInterval) {
                    // if the interval is greater than minimum interval defined as 4.5 characters time, it means it is a new frame
                    // new frame, reset the _receiveBuffer
                    _receiveBuffer = blob();
                    _shouldParseADU = true;
                }
                // read the first 8 bits
                _receiveBuffer.writen(data, 'b');
            }
            data = _uart.read();
        }
        if (_shouldParseADU && _receiveBuffer.len() >= MIN_REQUEST_LENGTH) {
            _processReceiveBuffer();
        }
    }

    //
    // it processes the buffer and return a response to the Master if applicable
    //
    function _processReceiveBuffer() {
        local ADU = null;
        local slaveID = null;
        try {
            _receiveBuffer.seek(0);
            local bufferLength = _receiveBuffer.len();
            slaveID = _receiveBuffer.readn('b');
            if (_slaveID != slaveID) {
                _shouldParseADU = false;
            }
            if (!_shouldParseADU) {
                return _receiveBuffer.seek(bufferLength);
            }
            local PDU = _receiveBuffer.readblob(bufferLength - 1);
            local result = ModbusSlave._parse(PDU);
            if (result == false) {
                return _receiveBuffer.seek(bufferLength);
            }
            // 2 bytes for CRC check and 1 byte for slaveID
            if (bufferLength < result.expectedReqLen + 3) {
                return _receiveBuffer.seek(bufferLength);
            }
            if (!_hasValidCRC()) {
                throw "Invalid CRC";
            }
            ADU = _createADU(_createPDU(result, slaveID), slaveID);
        } catch (error) {
            if (typeof error == "table") {
                ADU = _createADU(_createErrorPDU(error.functionCode, error.error), slaveID);
            } else {
                if (_onErrorCallback) {
                    _onErrorCallback(error);
                } else {
                    server.error(error);
                }
                return;
            }
        }
        _log(_receiveBuffer, "Incoming ADU : ");
        // return ADU to help with testing
        return _send(ADU);
    }

    //
    // the concrete function to create an ADU
    //
    function _createADU(PDU, slaveID) {
        local ADU = blob();
        ADU.writen(slaveID, 'b');
        ADU.writeblob(PDU);
        ADU.writen(CRC16.calculate(ADU), 'w');
        return ADU;
    }

    //
    // the concrete function to send a packet via RS485
    //
    function _send(ADU) {
        local rw = _rts.write.bindenv(_rts);
        local uw = _uart.write.bindenv(_uart);
        local uf = _uart.flush.bindenv(_uart);
        rw(1);
        uw(ADU);
        uf();
        rw(0);
        _log(ADU, "Outgoing ADU : ");
        // return ADU to help with testing
        return ADU;
    }

    //
    // verify if the packet is corrupted
    //
    function _hasValidCRC() {
        _receiveBuffer.seek(0);
        local content = _receiveBuffer.readblob(_receiveBuffer.len() - 2);
        local crc = _receiveBuffer.readn('w');
        return (crc == CRC16.calculate(content));
    }
}
