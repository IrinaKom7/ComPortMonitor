function Parse-Barcode {
    #[CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Barcode
    )

    $gsChar = [char]29  # ASCII group separator GS
    $fncChar = [char]232  # ASCII group separator FNC1
    $cr = [char]13  # ASCII group separator GS
    $lf = [char]10  # ASCII group separator FNC1
    $num_arr = 0..9 | ForEach-Object { "$_" }
    
    # Helper: create a new ParsedElement object
    function New-ParsedElement {
        param(
            [string]$ai,
            [string]$dataTitle,
            [string]$elementType
        )
        $obj = [PSCustomObject]@{
            ai        = $ai
            dataTitle = $dataTitle
            data      = $null
            unit      = ""
            len       = 0
        }
        switch ($elementType) {
            "S" { $obj.data = "" }
            "N" { $obj.data = 0 }
            "F" { $obj.data = "" } #Float
            "D" { $obj.data = [DateTime]::new(1, 1, 1, 0, 0, 0) }  # placeholder, will be set later
            "U" { $obj.data = "" } #Unknown
            default { $obj.data = "" }
        }
        return $obj
    }



    # Main identification function
    function Identify-AI {
        param([string]$codestring)
        
         if ($codestring.Length -lt 2 -or `
            ($num_arr -notcontains $codestring[0]) -or `
            ($num_arr -notcontains $codestring[1]))
         {
            $script:elementToReturn = New-ParsedElement -ai '??' -dataTitle "Unknown"  -elementType "U"
            $script:elementToReturn.data  = 'hex: ' + ($codestring.ToCharArray() | ForEach-Object { '{0:X2}' -f [byte]$_ }) -join ' '
            $script:elementToReturn.len = $codestring.Length
             
            $script:codestringToReturn = ""
            $answer = [PSCustomObject]@{
                codestring        = ""
                element = @()
            }
            $answer.element += $script:elementToReturn
            return  $answer
        }
        $script:codestringToReturn = ""  # will be set by parsing functions
        $script:elementToReturn = $null

        $firstNumber = $codestring.Substring(0, 1)
        $secondNumber = $codestring.Substring(1, 1)
        $thirdNumber = ""
        $fourthNumber = ""
        $codestringLength = $codestring.Length

        function pos_of_separator {
        param([string]$codestring)
            $res = -1
            $pos_fnc = $codestring.IndexOf($fncChar)
            $pos_gs  = $codestring.IndexOf($gsChar)
            if ($pos_fnc -gt -1 -and $pos_gs -gt -1)
            {
                $res = [Math]::Min($pos_fnc, $pos_gs)
            }
            elseif ($pos_fnc -gt -1) {
                $res = $pos_fnc
            }elseif ($pos_gs -gt -1) {
                $res = $pos_gs
            }
            return $res
        }
        function pos_of_cr_lf {
        param([string]$codestring)
            $res = -1
            $pos_cr = $codestring.IndexOf($cr)
            $pos_lf  = $codestring.IndexOf($lf)
            if ($pos_cr -gt -1 -and $pos_lf -gt -1)
            {
                $res = [Math]::Min($pos_cr, $pos_lf)
            }
            elseif ($pos_cr -gt -1) {
                $res = $pos_cr
            }elseif ($pos_lf -gt -1) {
                $res = $pos_lf
            }
            return $res
        }

        # Helper: remove leading FNC chars
        function Clean-Codestring {
            param([string]$stringToClean)
            while ($stringToClean -and ($stringToClean[0] -eq $fncChar -or $stringToClean[0] -eq $gsChar)) {
                $stringToClean = $stringToClean.Substring(1)
            }
            return $stringToClean
        }

        # ?Helper: parse floating point from string with given fractional digits
        function Parse-FloatingPoint {
            param([string]$stringToParse, [int]$numberOfFractionals)
            if ($numberOfFractionals -le 0) {
                return [double]$stringToParse
            }
            $offset = $stringToParse.Length - $numberOfFractionals
            if ($offset -le 0) {
                # If string is shorter than fractional digits, pad with leading zeros
                $stringToParse = $stringToParse.PadLeft($numberOfFractionals + 1, '0')
                $offset = 1
            }
            $auxString = $stringToParse.Substring(0, $offset) + '.' + $stringToParse.Substring($offset)
            try {
                return [double]$auxString
            } catch {
                throw "invalid number"
            }
        }

        # Parsing functions used inside identifyAI

        function Parse-Date {
            param([string]$ai, [string]$title)
            $script:elementToReturn = New-ParsedElement -ai $ai -dataTitle $title -elementType "D"
            $offset = $ai.Length
            $dateYYMMDD = $codestring.Substring($offset, 6)
            try {
                $yearAsNumber = [int]$dateYYMMDD.Substring(0, 2)
                $monthAsNumber = [int]$dateYYMMDD.Substring(2, 2)
                $dayAsNumber = [int]$dateYYMMDD.Substring(4, 2)
            } catch {
                throw "invalid date component"
            }

            # Century rule: 51-99 -> 1900, 00-50 -> 2000
            if ($yearAsNumber -gt 50) {
                $yearAsNumber += 1900
            } else {
                $yearAsNumber += 2000
            }


            # Create DateTime
            $script:elementToReturn.data = [DateTime]::new($yearAsNumber, $monthAsNumber, $dayAsNumber)
            $script:elementToReturn.len = $dateYYMMDD.Length
            $script:codestringToReturn = $codestring.Substring($offset + 6)
        }

        function Parse-FixedLength {
            param([string]$ai, [string]$title, [int]$length)
            $tmp = New-ParsedElement -ai $ai -dataTitle $title -elementType "S"
            $script:elementToReturn = New-ParsedElement -ai $ai -dataTitle $title -elementType "S"
            $offset = $ai.Length
            $script:elementToReturn.data = $codestring.Substring($offset, $length)
            $script:elementToReturn.len = $script:elementToReturn.data.Length
            $script:codestringToReturn = $codestring.Substring($offset + $length)
        }

        function Parse-VariableLength {
            param([string]$ai, [string]$title)
            $script:elementToReturn = New-ParsedElement -ai $ai -dataTitle $title -elementType "S"
            $offset = $ai.Length
            #$posOfFNC = $codestring.IndexOf($fncChar)
            $posOfFNC = pos_of_separator($codestring)
            $posOf_cr_lf = pos_of_cr_lf($codestring)
            #Если разделителя нет - это последний сегмент в коде
            if ($posOfFNC -eq -1) {
                # Если сканер передал возврат строки
                if ($posOf_cr_lf -gt -1){
                    #Если в строке найден возврат строки, копируем текст до возврата строки 
                    #Начиная с возврата строки передаем на следующий цикл парсинга
                    $script:elementToReturn.data = $codestring.Substring($offset, $posOf_cr_lf - $offset)
                    $script:elementToReturn.len = $script:elementToReturn.data.Length
                    $script:codestringToReturn = $codestring.Substring($posOf_cr_lf)
                } else{
                    #Иначе с места окончания текущего AI (пропускаем AI)
                    $script:elementToReturn.data = $codestring.Substring($offset)
                    $script:elementToReturn.len = $script:elementToReturn.data.Length
                    $script:codestringToReturn = ""
                }


            } else {
                $script:elementToReturn.data = $codestring.Substring($offset, $posOfFNC - $offset)
                $script:elementToReturn.len = $script:elementToReturn.data.Length
                $script:codestringToReturn = $codestring.Substring($posOfFNC + 1)
            }
        }

        function Parse-FixedLengthMeasure {
            param([string]$ai_stem, [string]$fourthNumber, [string]$title, [string]$unit)
            $fullAI = $ai_stem + $fourthNumber
            $script:elementToReturn = New-ParsedElement -ai $fullAI -dataTitle $title -elementType "F"
            $offset = $ai_stem.Length + 1
            $numberOfDecimals = [int]$fourthNumber
            $numberPart = $codestring.Substring($offset, 6)
            #$script:elementToReturn.data = Parse-FloatingPoint -stringToParse $numberPart -numberOfFractionals $numberOfDecimals
            $tmp = Parse-FloatingPoint -stringToParse $numberPart -numberOfFractionals $numberOfDecimals
            $script:elementToReturn.data = "{0:F$numberOfDecimals}" -f $tmp 
            $script:elementToReturn.len = $numberPart.Length
            $script:elementToReturn.unit = $unit
            $script:codestringToReturn = $codestring.Substring($offset + 6)
        }

        function Parse-VariableLengthMeasure {
            param([string]$ai_stem, [string]$fourthNumber, [string]$title, [string]$unit)
            $fullAI = $ai_stem + $fourthNumber
            $script:elementToReturn = New-ParsedElement -ai $fullAI -dataTitle $title -elementType "N"
            $offset = $ai_stem.Length + 1
            #$posOfFNC = $codestring.IndexOf($fncChar)
            $posOfFNC = pos_of_separator($codestring)
            $numberOfDecimals = [int]$fourthNumber
            if ($posOfFNC -eq -1) {
                $numberPart = $codestring.Substring($offset)
                $script:codestringToReturn = ""
            } else {
                $numberPart = $codestring.Substring($offset, $posOfFNC - $offset)
                $script:codestringToReturn = $codestring.Substring($posOfFNC + 1)
            }
            
            #$script:elementToReturn.data = Parse-FloatingPoint -stringToParse $numberPart -numberOfFractionals $numberOfDecimals
            $script:elementToReturn.data = Parse-FloatingPoint -stringToParse $numberPart -numberOfFractionals $numberOfDecimals
            $script:elementToReturn.len = $numberPart.Length
            $script:elementToReturn.unit = $unit
        }

        function Parse-VariableLengthWithISONumbers {
            param([string]$ai_stem, [string]$fourthNumber, [string]$title)
            $fullAI = $ai_stem + $fourthNumber
            $script:elementToReturn = New-ParsedElement -ai $fullAI -dataTitle $title -elementType "N"
            $offset = $ai_stem.Length + 1
            #$posOfFNC = $codestring.IndexOf($fncChar)
            $posOfFNC = pos_of_separator($codestring)
            $numberOfDecimals = [int]$fourthNumber
            if ($posOfFNC -eq -1) {
                $isoPlusNumbers = $codestring.Substring($offset)
                $script:codestringToReturn = ""
            } else {
                $isoPlusNumbers = $codestring.Substring($offset, $posOfFNC - $offset)
                $script:codestringToReturn = $codestring.Substring($posOfFNC + 1)
            }
            $numberPart = $isoPlusNumbers.Substring(3)  # skip ISO code (3 chars)
            $script:elementToReturn.data = Parse-FloatingPoint -stringToParse $numberPart -numberOfFractionals $numberOfDecimals
            $script:elementToReturn.len = $offset
            $script:elementToReturn.unit = $isoPlusNumbers.Substring(0, 3)
        }

        function Parse-VariableLengthWithISOChars {
            param([string]$ai_stem, [string]$title)
            $fullAI = $ai_stem
            $script:elementToReturn = New-ParsedElement -ai $fullAI -dataTitle $title -elementType "S"
            $offset = $ai_stem.Length
            #$posOfFNC = $codestring.IndexOf($fncChar)
            $posOfFNC = pos_of_separator($codestring)
            if ($posOfFNC -eq -1) {
                $isoPlusNumbers = $codestring.Substring($offset)
                $script:codestringToReturn = ""
            } else {
                $isoPlusNumbers = $codestring.Substring($offset, $posOfFNC - $offset)
                $script:codestringToReturn = $codestring.Substring($posOfFNC + 1)
            }
            $script:elementToReturn.data = $isoPlusNumbers.Substring(3)  # skip ISO code
            $script:elementToReturn.len = $script:elementToReturn.data.Length
            $script:elementToReturn.unit = $isoPlusNumbers.Substring(0, 3)
        }

        # Big switch as in JS
        switch ($firstNumber) {
            "0" {
                switch ($secondNumber) {
                    "0" { Parse-FixedLength -ai "00" -title "SSCC" -length 18 }
                    "1" { Parse-FixedLength -ai "01" -title "GTIN" -length 14 }
                    "2" { Parse-FixedLength -ai "02" -title "CONTENT" -length 14 }
                    default { throw "invalid AI after '0'" }
                }
            }
            "1" {
                switch ($secondNumber) {
                    "0" { Parse-VariableLength -ai "10" -title "BATCH/LOT" }
                    "1" { Parse-Date -ai "11" -title "PROD DATE" }
                    "2" { Parse-Date -ai "12" -title "DUE DATE" }
                    "3" { Parse-Date -ai "13" -title "PACK DATE" }
                    "5" { Parse-Date -ai "15" -title "BEST BEFORE or BEST BY" }
                    "6" { Parse-Date -ai "16" -title "SELL BY" }
                    "7" { Parse-Date -ai "17" -title "USE BY OR EXPIRY" }
                    default { throw "invalid AI after '1'" }
                }
            }
            "2" {
                switch ($secondNumber) {
                    "0" { Parse-FixedLength -ai "20" -title "VARIANT" -length 2 }
                    "1" { Parse-VariableLength -ai "21" -title "SERIAL" }
                    "2" { Parse-VariableLength -ai "22" -title "CPV" }
                    "4" {
                        $thirdNumber = $codestring.Substring(2, 1)
                        switch ($thirdNumber) {
                            "0" { Parse-VariableLength -ai "240" -title "ADDITIONAL ID" }
                            "1" { Parse-VariableLength -ai "241" -title "CUST. PART NO." }
                            "2" { Parse-VariableLength -ai "242" -title "MTO VARIANT" }
                            "3" { Parse-VariableLength -ai "243" -title "PCN" }
                            default { throw "invalid AI after '24'" }
                        }
                    }
                    "5" {
                        $thirdNumber = $codestring.Substring(2, 1)
                        switch ($thirdNumber) {
                            "0" { Parse-VariableLength -ai "250" -title "SECONDARY SERIAL" }
                            "1" { Parse-VariableLength -ai "251" -title "REF. TO SOURCE" }
                            "3" { Parse-VariableLength -ai "253" -title "GDTI" }
                            "4" { Parse-VariableLength -ai "254" -title "GLN EXTENSION COMPONENT" }
                            "5" { Parse-VariableLength -ai "255" -title "GCN" }
                            default { throw "invalid AI after '25'" }
                        }
                    }
                    default { throw "invalid AI after '2'" }
                }
            }
            "3" {
                switch ($secondNumber) {
                    "0" { Parse-VariableLength -ai "30" -title "VAR. COUNT" }
                    "1" {
                        $thirdNumber = $codestring.Substring(2, 1)
                        $fourthNumber = $codestring.Substring(3, 1)
                        switch ($thirdNumber) {
                            "0" { Parse-FixedLengthMeasure -ai_stem "310" -fourthNumber $fourthNumber -title "NET WEIGHT (kg)" -unit "KGM" }
                            "1" { Parse-FixedLengthMeasure -ai_stem "311" -fourthNumber $fourthNumber -title "LENGTH (m)" -unit "MTR" }
                            "2" { Parse-FixedLengthMeasure -ai_stem "312" -fourthNumber $fourthNumber -title "WIDTH (m)" -unit "MTR" }
                            "3" { Parse-FixedLengthMeasure -ai_stem "313" -fourthNumber $fourthNumber -title "HEIGHT (m)" -unit "MTR" }
                            "4" { Parse-FixedLengthMeasure -ai_stem "314" -fourthNumber $fourthNumber -title "AREA (m2)" -unit "MTK" }
                            "5" { Parse-FixedLengthMeasure -ai_stem "315" -fourthNumber $fourthNumber -title "NET VOLUME (l)" -unit "LTR" }
                            "6" { Parse-FixedLengthMeasure -ai_stem "316" -fourthNumber $fourthNumber -title "NET VOLUME (m3)" -unit "MTQ" }
                            default { throw "invalid AI after '31'" }
                        }
                    }
                    "2" {
                        $thirdNumber = $codestring.Substring(2, 1)
                        $fourthNumber = $codestring.Substring(3, 1)
                        switch ($thirdNumber) {
                            "0" { Parse-FixedLengthMeasure -ai_stem "320" -fourthNumber $fourthNumber -title "NET WEIGHT (lb)" -unit "LBR" }
                            "1" { Parse-FixedLengthMeasure -ai_stem "321" -fourthNumber $fourthNumber -title "LENGTH (i)" -unit "INH" }
                            "2" { Parse-FixedLengthMeasure -ai_stem "322" -fourthNumber $fourthNumber -title "LENGTH (f)" -unit "FOT" }
                            "3" { Parse-FixedLengthMeasure -ai_stem "323" -fourthNumber $fourthNumber -title "LENGTH (y)" -unit "YRD" }
                            "4" { Parse-FixedLengthMeasure -ai_stem "324" -fourthNumber $fourthNumber -title "WIDTH (i)" -unit "INH" }
                            "5" { Parse-FixedLengthMeasure -ai_stem "325" -fourthNumber $fourthNumber -title "WIDTH (f)" -unit "FOT" }
                            "6" { Parse-FixedLengthMeasure -ai_stem "326" -fourthNumber $fourthNumber -title "WIDTH (y)" -unit "YRD" }
                            "7" { Parse-FixedLengthMeasure -ai_stem "327" -fourthNumber $fourthNumber -title "HEIGHT (i)" -unit "INH" }
                            "8" { Parse-FixedLengthMeasure -ai_stem "328" -fourthNumber $fourthNumber -title "HEIGHT (f)" -unit "FOT" }
                            "9" { Parse-FixedLengthMeasure -ai_stem "329" -fourthNumber $fourthNumber -title "HEIGHT (y)" -unit "YRD" }
                            default { throw "invalid AI after '32'" }
                        }
                    }
                    "3" {
                        $thirdNumber = $codestring.Substring(2, 1)
                        $fourthNumber = $codestring.Substring(3, 1)
                        switch ($thirdNumber) {
                            "0" { Parse-FixedLengthMeasure -ai_stem "330" -fourthNumber $fourthNumber -title "GROSS WEIGHT (kg)" -unit "KGM" }
                            "1" { Parse-FixedLengthMeasure -ai_stem "331" -fourthNumber $fourthNumber -title "LENGTH (m), log" -unit "MTR" }
                            "2" { Parse-FixedLengthMeasure -ai_stem "332" -fourthNumber $fourthNumber -title "WIDTH (m), log" -unit "MTR" }
                            "3" { Parse-FixedLengthMeasure -ai_stem "333" -fourthNumber $fourthNumber -title "HEIGHT (m), log" -unit "MTR" }
                            "4" { Parse-FixedLengthMeasure -ai_stem "334" -fourthNumber $fourthNumber -title "AREA (m2), log" -unit "MTK" }
                            "5" { Parse-FixedLengthMeasure -ai_stem "335" -fourthNumber $fourthNumber -title "VOLUME (l), log" -unit "LTR" }
                            "6" { Parse-FixedLengthMeasure -ai_stem "336" -fourthNumber $fourthNumber -title "VOLUME (m3), log" -unit "MTQ" }
                            "7" { Parse-FixedLengthMeasure -ai_stem "337" -fourthNumber $fourthNumber -title "KG PER mВІ" -unit "28" }
                            default { throw "invalid AI after '33'" }
                        }
                    }
                    "4" {
                        $thirdNumber = $codestring.Substring(2, 1)
                        $fourthNumber = $codestring.Substring(3, 1)
                        switch ($thirdNumber) {
                            "0" { Parse-FixedLengthMeasure -ai_stem "340" -fourthNumber $fourthNumber -title "GROSS WEIGHT (lb)" -unit "LBR" }
                            "1" { Parse-FixedLengthMeasure -ai_stem "341" -fourthNumber $fourthNumber -title "LENGTH (i), log" -unit "INH" }
                            "2" { Parse-FixedLengthMeasure -ai_stem "342" -fourthNumber $fourthNumber -title "LENGTH (f), log" -unit "FOT" }
                            "3" { Parse-FixedLengthMeasure -ai_stem "343" -fourthNumber $fourthNumber -title "LENGTH (y), log" -unit "YRD" }
                            "4" { Parse-FixedLengthMeasure -ai_stem "344" -fourthNumber $fourthNumber -title "WIDTH (i), log" -unit "INH" }
                            "5" { Parse-FixedLengthMeasure -ai_stem "345" -fourthNumber $fourthNumber -title "WIDTH (f), log" -unit "FOT" }
                            "6" { Parse-FixedLengthMeasure -ai_stem "346" -fourthNumber $fourthNumber -title "WIDTH (y), log" -unit "YRD" }
                            "7" { Parse-FixedLengthMeasure -ai_stem "347" -fourthNumber $fourthNumber -title "HEIGHT (i), log" -unit "INH" }
                            "8" { Parse-FixedLengthMeasure -ai_stem "348" -fourthNumber $fourthNumber -title "HEIGHT (f), log" -unit "FOT" }
                            "9" { Parse-FixedLengthMeasure -ai_stem "349" -fourthNumber $fourthNumber -title "HEIGHT (y), log" -unit "YRD" }
                            default { throw "invalid AI after '34'" }
                        }
                    }
                    "5" {
                        $thirdNumber = $codestring.Substring(2, 1)
                        $fourthNumber = $codestring.Substring(3, 1)
                        switch ($thirdNumber) {
                            "0" { Parse-FixedLengthMeasure -ai_stem "350" -fourthNumber $fourthNumber -title "AREA (i2)" -unit "INK" }
                            "1" { Parse-FixedLengthMeasure -ai_stem "351" -fourthNumber $fourthNumber -title "AREA (f2)" -unit "FTK" }
                            "2" { Parse-FixedLengthMeasure -ai_stem "352" -fourthNumber $fourthNumber -title "AREA (y2)" -unit "YDK" }
                            "3" { Parse-FixedLengthMeasure -ai_stem "353" -fourthNumber $fourthNumber -title "AREA (i2), log" -unit "INK" }
                            "4" { Parse-FixedLengthMeasure -ai_stem "354" -fourthNumber $fourthNumber -title "AREA (f2), log" -unit "FTK" }
                            "5" { Parse-FixedLengthMeasure -ai_stem "355" -fourthNumber $fourthNumber -title "AREA (y2), log" -unit "YDK" }
                            "6" { Parse-FixedLengthMeasure -ai_stem "356" -fourthNumber $fourthNumber -title "NET WEIGHT (t)" -unit "APZ" }
                            "7" { Parse-FixedLengthMeasure -ai_stem "357" -fourthNumber $fourthNumber -title "NET VOLUME (oz)" -unit "ONZ" }
                            default { throw "invalid AI after '35'" }
                        }
                    }
                    "6" {
                        $thirdNumber = $codestring.Substring(2, 1)
                        $fourthNumber = $codestring.Substring(3, 1)
                        switch ($thirdNumber) {
                            "0" { Parse-FixedLengthMeasure -ai_stem "360" -fourthNumber $fourthNumber -title "NET VOLUME (q)" -unit "QT" }
                            "1" { Parse-FixedLengthMeasure -ai_stem "361" -fourthNumber $fourthNumber -title "NET VOLUME (g)" -unit "GLL" }
                            "2" { Parse-FixedLengthMeasure -ai_stem "362" -fourthNumber $fourthNumber -title "VOLUME (q), log" -unit "QT" }
                            "3" { Parse-FixedLengthMeasure -ai_stem "363" -fourthNumber $fourthNumber -title "VOLUME (g), log" -unit "GLL" }
                            "4" { Parse-FixedLengthMeasure -ai_stem "364" -fourthNumber $fourthNumber -title "VOLUME (i3)" -unit "INQ" }
                            "5" { Parse-FixedLengthMeasure -ai_stem "365" -fourthNumber $fourthNumber -title "VOLUME (f3)" -unit "FTQ" }
                            "6" { Parse-FixedLengthMeasure -ai_stem "366" -fourthNumber $fourthNumber -title "VOLUME (y3)" -unit "YDQ" }
                            "7" { Parse-FixedLengthMeasure -ai_stem "367" -fourthNumber $fourthNumber -title "VOLUME (i3), log" -unit "INQ" }
                            "8" { Parse-FixedLengthMeasure -ai_stem "368" -fourthNumber $fourthNumber -title "VOLUME (f3), log" -unit "FTQ" }
                            "9" { Parse-FixedLengthMeasure -ai_stem "369" -fourthNumber $fourthNumber -title "VOLUME (y3), log" -unit "YDQ" }
                            default { throw "invalid AI after '36'" }
                        }
                    }
                    "7" { Parse-VariableLength -ai "37" -title "COUNT" }
                    "9" {
                        $thirdNumber = $codestring.Substring(2, 1)
                        $fourthNumber = $codestring.Substring(3, 1)
                        switch ($thirdNumber) {
                            "0" { Parse-VariableLengthMeasure -ai_stem "390" -fourthNumber $fourthNumber -title "AMOUNT" -unit "" }
                            "1" { Parse-VariableLengthWithISONumbers -ai_stem "391" -fourthNumber $fourthNumber -title "AMOUNT" }
                            "2" { Parse-VariableLengthMeasure -ai_stem "392" -fourthNumber $fourthNumber -title "PRICE" -unit "" }
                            "3" { Parse-VariableLengthWithISONumbers -ai_stem "393" -fourthNumber $fourthNumber -title "PRICE" }
                            default { throw "invalid AI after '39'" }
                        }
                    }
                    default { throw "invalid AI after '3'" }
                }
            }
            "4" {
                switch ($secondNumber) {
                    "0" {
                        $thirdNumber = $codestring.Substring(2, 1)
                        switch ($thirdNumber) {
                            "0" { Parse-VariableLength -ai "400" -title "ORDER NUMBER" }
                            "1" { Parse-VariableLength -ai "401" -title "GINC" }
                            "2" { Parse-VariableLength -ai "402" -title "GSIN" }
                            "3" { Parse-VariableLength -ai "403" -title "ROUTE" }
                            default { throw "invalid AI after '40'" }
                        }
                    }
                    "1" {
                        $thirdNumber = $codestring.Substring(2, 1)
                        switch ($thirdNumber) {
                            "0" { Parse-FixedLength -ai "410" -title "SHIP TO LOC" -length 13 }
                            "1" { Parse-FixedLength -ai "411" -title "BILL TO" -length 13 }
                            "2" { Parse-FixedLength -ai "412" -title "PURCHASE FROM" -length 13 }
                            "3" { Parse-FixedLength -ai "413" -title "SHIP FOR LOC" -length 13 }
                            default { throw "invalid AI after '41'" }
                        }
                    }
                    "2" {
                        $thirdNumber = $codestring.Substring(2, 1)
                        switch ($thirdNumber) {
                            "0" { Parse-VariableLength -ai "420" -title "SHIP TO POST" }
                            "1" { Parse-VariableLengthWithISOChars -ai_stem "421" -title "SHIP TO POST" }
                            "2" { Parse-FixedLength -ai "422" -title "ORIGIN" -length 3 }
                            "3" { Parse-VariableLength -ai "423" -title "COUNTRY - INITIAL PROCESS." }
                            "4" { Parse-FixedLength -ai "424" -title "COUNTRY - PROCESS." -length 3 }
                            "5" { Parse-FixedLength -ai "425" -title "COUNTRY - DISASSEMBLY" -length 3 }
                            "6" { Parse-FixedLength -ai "426" -title "COUNTRY вЂ“ FULL PROCESS" -length 3 }
                            "7" { Parse-VariableLength -ai "427" -title "ORIGIN SUBDIVISION" }
                            default { throw "invalid AI after '42'" }
                        }
                    }
                    default { throw "invalid AI after '4'" }
                }
            }
            "7" {
                switch ($secondNumber) {
                    "0" {
                        $thirdNumber = $codestring.Substring(2, 1)
                        $fourthNumber = $codestring.Substring(3, 1)
                        switch ($thirdNumber) {
                            "0" {
                                switch ($fourthNumber) {
                                    "1" { Parse-VariableLength -ai "7001" -title "NSN" }
                                    "2" { Parse-VariableLength -ai "7002" -title "MEAT CUT" }
                                    "3" { Parse-VariableLength -ai "7003" -title "EXPIRY TIME" }
                                    "4" { Parse-VariableLength -ai "7004" -title "ACTIVE POTENCY" }
                                    default { throw "invalid AI after '700'" }
                                }
                            }
                            "3" {
                                # 703 + fourthNumber (as string) - title includes the fourth digit
                                $ai = "703" + $fourthNumber
                                $title = "PROCESSOR # " + $fourthNumber
                                Parse-VariableLengthWithISOChars -ai_stem $ai -title $title
                            }
                            default { throw "invalid AI after '70'" }
                        }
                    }
                    "1" {
                        $thirdNumber = $codestring.Substring(2, 1)
                        switch ($thirdNumber) {
                            "0" { Parse-VariableLength -ai "710" -title "NHRN PZN" }
                            "1" { Parse-VariableLength -ai "711" -title "NHRN CIP" }
                            "2" { Parse-VariableLength -ai "712" -title "NHRN CN" }
                            "3" { Parse-VariableLength -ai "713" -title "NHRN DRN" }
                            default { throw "invalid AI after '71'" }
                        }
                    }
                    default { throw "invalid AI after '7'" }
                }
            }
            "8" {
                switch ($secondNumber) {
                    "0" {
                        $thirdNumber = $codestring.Substring(2, 1)
                        $fourthNumber = $codestring.Substring(3, 1)
                        switch ($thirdNumber) {
                            "0" {
                                switch ($fourthNumber) {
                                    "1" { Parse-VariableLength -ai "8001" -title "DIMENSIONS" }
                                    "2" { Parse-VariableLength -ai "8002" -title "CMT No" }
                                    "3" { Parse-VariableLength -ai "8003" -title "GRAI" }
                                    "4" { Parse-VariableLength -ai "8004" -title "GIAI" }
                                    "5" { Parse-VariableLength -ai "8005" -title "PRICE PER UNIT" }
                                    "6" { Parse-VariableLength -ai "8006" -title "GCTIN" }
                                    "7" { Parse-VariableLength -ai "8007" -title "IBAN" }
                                    "8" { Parse-VariableLength -ai "8008" -title "PROD TIME" }
                                    default { throw "invalid AI after '800'" }
                                }
                            }
                            "1" {
                                switch ($fourthNumber) {
                                    "0" { Parse-VariableLength -ai "8010" -title "CPID" }
                                    "1" { Parse-VariableLength -ai "8011" -title "CPID SERIAL" }
                                    "7" { Parse-VariableLength -ai "8017" -title "GSRN - PROVIDER" }
                                    "8" { Parse-VariableLength -ai "8018" -title "GSRN - RECIPIENT" }
                                    "9" { Parse-VariableLength -ai "8019" -title "SRIN" }
                                    default { throw "invalid AI after '801'" }
                                }
                            }
                            "2" {
                                switch ($fourthNumber) {
                                    "0" { Parse-VariableLength -ai "8020" -title "REF No" }
                                    default { throw "invalid AI after '802'" }
                                }
                            }
                            default { throw "invalid AI after '80'" }
                        }
                    }
                    "1" {
                        $thirdNumber = $codestring.Substring(2, 1)
                        $fourthNumber = $codestring.Substring(3, 1)
                        switch ($thirdNumber) {
                            "0" {
                                switch ($fourthNumber) {
                                    "0" { Parse-VariableLength -ai "8100" -title "-" }
                                    "1" { Parse-VariableLength -ai "8101" -title "-" }
                                    "2" { Parse-VariableLength -ai "8102" -title "-" }
                                    default { throw "invalid AI after '810'" }
                                }
                            }
                            "1" {
                                switch ($fourthNumber) {
                                    "0" { Parse-VariableLength -ai "8110" -title "-" }
                                    default { throw "invalid AI after '811'" }
                                }
                            }
                            default { throw "invalid AI after '81'" }
                        }
                    }
                    "2" {
                        $thirdNumber = $codestring.Substring(2, 1)
                        switch ($thirdNumber) {
                            "0" { Parse-VariableLength -ai "8200" -title "PRODUCT URL" }
                            default { throw "invalid AI after '82'" }
                        }
                    }
                    default { throw "invalid AI after '8'" }
                }
            }
            "9" {
                switch ($secondNumber) {
                    "0" { Parse-VariableLength -ai "90" -title "INTERNAL" }
                    "1" { Parse-VariableLength -ai "91" -title "Crypto1" }
                    "2" { Parse-VariableLength -ai "92" -title "Crypto2" }
                    "3" { Parse-VariableLength -ai "93" -title "Crypto" }
                    "4" { Parse-VariableLength -ai "94" -title "INTERNAL" }
                    "5" { Parse-VariableLength -ai "95" -title "INTERNAL" }
                    "6" { Parse-VariableLength -ai "96" -title "INTERNAL" }
                    "7" { Parse-VariableLength -ai "97" -title "INTERNAL" }
                    "8" { Parse-VariableLength -ai "98" -title "INTERNAL" }
                    "9" { Parse-VariableLength -ai "99" -title "INTERNAL" }
                    default { throw "invalid AI after '9'" }
                }
            }
            default { throw "no valid AI" }
        }

        # After the parsing functions, we have $script:elementToReturn and $script:codestringToReturn
        return @{
            element   = $script:elementToReturn
            codestring = Clean-Codestring -stringToClean $script:codestringToReturn
        }
    }

    # ==================== MAIN ====================
    $answer = [PSCustomObject]@{
        codeName        = ""
        parsedCodeItems = @()
    }

    $barcodelength = $Barcode.Length
    $symbologyIdentifier = $Barcode.Substring(0, [Math]::Min(3, $barcodelength))
    $restOfBarcode = ""

    # Strip symbology identifier if present
    switch ($symbologyIdentifier) {
        "]C1" {
            $answer.codeName = "GS1-128"
            $restOfBarcode = $Barcode.Substring(3)
        }
        "]e0" {
            $answer.codeName = "GS1 DataBar"
            $restOfBarcode = $Barcode.Substring(3)
        }
        "]e1" {
            $answer.codeName = "GS1 Composite"
            $restOfBarcode = $Barcode.Substring(3)
        }
        "]e2" {
            $answer.codeName = "GS1 Composite"
            $restOfBarcode = $Barcode.Substring(3)
        }
        "]d0" {
            $answer.codeName = "GS1 DataMatrix, ECC 000-140"
            $restOfBarcode = $Barcode.Substring(3)
        }
        "]d1" {
            $answer.codeName = "GS1 DataMatrix, ECC 200, FNC1 in first or fifth position"
            $restOfBarcode = $Barcode.Substring(3)
        }
        "]d2" {
            $answer.codeName = "GS1 DataMatrix, ECC 200"
            $restOfBarcode = $Barcode.Substring(3)
        }
        "]Q3" {
            $answer.codeName = "GS1 QR Code"
            $restOfBarcode = $Barcode.Substring(3)
        }
        default {
            $answer.codeName = ""
            $restOfBarcode = $Barcode
        }
    }

    # Now parse the rest in a loop
    while ($restOfBarcode.Length -gt 0) {
        try {
            $firstElement = Identify-AI -codestring $restOfBarcode
            $restOfBarcode = $firstElement.codestring
            $answer.parsedCodeItems += $firstElement.element
        } catch {
            # Re-throw with more descriptive message
            throw $_.Exception.Message
        }
    }

    return  $answer
}



Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ------------------- Глобальные переменные -------------------
$script:serialPort = $null
$script:timer = $null

# ------------------- Функция добавления данных в RichTextBox -------------------
function Add-BytesToOutput {
    param([byte[]]$bytes)

    if ($null -eq $bytes -or $bytes.Count -eq 0) { return }

    $rtb = $script:richTextBox
    $rtb.SuspendLayout()

    # ---------- Строка hex-кодов ----------
    for ($i = 0; $i -lt $bytes.Count; $i++) {
        $b = $bytes[$i]
        $hex = "{0:X2}" -f $b

        if ($b -eq 29)      { $rtb.SelectionBackColor = 'Green' }
        elseif ($b -eq 232) { $rtb.SelectionBackColor = 'Red' }
        else                { $rtb.SelectionBackColor = $rtb.BackColor }

        $rtb.AppendText($hex)

        if ($i -lt $bytes.Count - 1) {
            $rtb.SelectionColor = $rtb.ForeColor
            $rtb.AppendText(" ")
        }
    }
    $rtb.SelectionColor = $rtb.ForeColor
    $rtb.AppendText("`r")  # Перевод строки
    
    # ---------- Строка ASCII-символов ----------
    for ($i = 0; $i -lt $bytes.Count; $i++) {
        $b = $bytes[$i]
        $char = if ($b -ge 32 -and $b -le 126) { [char]$b } else { '.' }

        if ($b -eq 29)      { $rtb.SelectionBackColor = 'Green'; $rtb.AppendText('GS') }
        elseif ($b -eq 232) { $rtb.SelectionBackColor = 'Red' ; $rtb.AppendText('F1')}
        else                { $rtb.SelectionBackColor = $rtb.BackColor; $rtb.AppendText( " " + $char)}

        

        if ($i -lt $bytes.Count - 1) {
            $rtb.SelectionColor = $rtb.ForeColor
            $rtb.AppendText(" ")  # Два пробела для выравнивания под hex (2 символа + пробел)
        }
    }
    $rtb.SelectionColor = $rtb.ForeColor
    $rtb.AppendText("`r`r")

    
    $barcode = ($bytes | ForEach-Object { [char]$_ }) -join ''
    #Рекомендуется использовать явную кодировку
    #$barcode = [System.Text.Encoding]::ASCII.GetString($bytes) ###########


    $tmp_res = (Parse-Barcode($barcode)).parsedCodeItems
    $have_unit = $false
    foreach($ai in $tmp_res){
        if ($ai.unit -ne "") {
            $have_unit = $true
            break
        }
    }
    if ($have_unit){
        $out_str = $tmp_res | Select-Object @{N='AI';E={$_.ai}}, @{N='Type';E={$_.dataTitle}} , `
            @{N='Data';E={$_.data}}, @{N='Unit';E={$_.unit}}, @{N='Lenght';E={$_.len}}`
            | Format-Table -AutoSize | Out-String 
    } else {
        $out_str = $tmp_res | Select-Object @{N='AI';E={$_.ai}}, @{N='Type';E={$_.dataTitle}} , `
            @{N='Data';E={$_.data}}, @{N='Lenght';E={$_.len}}`
            | Format-Table -AutoSize | Out-String 
    }

    $rtb.AppendText($out_str)

    $rtb.ResumeLayout()
    # Автопрокрутка вниз
    $rtb.ScrollToCaret()
}

# ------------------- Обработчики кнопок -------------------
function Connect-Port {
    $btnConnect.Enabled = $false
    try {
        $portName = $comboPort.SelectedItem.ToString()
        $baud     = [int]$comboBaud.SelectedItem
        $dataBits = [int]$comboData.SelectedItem
        $parity   = $comboParity.SelectedItem
        $stopBits = $comboStop.SelectedItem

        $script:serialPort = New-Object System.IO.Ports.SerialPort $portName, $baud, $parity, $dataBits, $stopBits
        $script:serialPort.ReadTimeout = 100
        $script:serialPort.WriteTimeout = 100
        $script:serialPort.Open()

        # Запускаем таймер для опроса порта
        $script:timer = New-Object System.Windows.Forms.Timer
        
        
        <#
        Потенциальный deadlock или пропуск данных при чтении порта
        Таймер опрашивает порт каждые 50 мс. Если данных много, 
        буфер может переполниться, а Read может не успеть прочитать всё. 
        Лучше использовать событие DataReceived, 
        но оно требует синхронизации с UI. 
        В вашем случае можно увеличить интервал или читать в цикле, пока есть данные.
        #>
                
        #$script:timer.Interval = 50   # миллисекунды
        $script:timer.Interval = 100   # миллисекунды
        $script:timer.Add_Tick({
            if ($null -ne $script:serialPort  -and $script:serialPort.IsOpen) {
                $count = $script:serialPort.BytesToRead
                if ($count -gt 0) {
                    $buffer = New-Object byte[] $count
                    $read = $script:serialPort.Read($buffer, 0, $count)
                    if ($read -gt 0) {
                        $data = $buffer[0..($read-1)]
                        Add-BytesToOutput -bytes $data
                    }
                }
            }
        })
        $script:timer.Start()

        $btnDisconnect.Enabled = $true
        $status.Text = "Connected to $portName"
        $status.ForeColor = 'Green'
    }
    catch {
        $status.Text = "Error: $($_.Exception.Message)"
        $status.ForeColor = 'Red'
        $btnConnect.Enabled = $true
        if ($script:serialPort) { $script:serialPort.Dispose(); $script:serialPort = $null }
    }
}

function Disconnect-Port {
    if ($script:timer) {
        $script:timer.Stop()
        $script:timer.Dispose()
        $script:timer = $null
    }
    if ($script:serialPort) {
        if ($script:serialPort.IsOpen) { $script:serialPort.Close() }
        $script:serialPort.Dispose()
        $script:serialPort = $null
    }
    $btnConnect.Enabled = $true
    $btnDisconnect.Enabled = $false
    $status.Text = "Disconnected"
    $status.ForeColor = 'Black'
}

function Clear-Output {
    $script:richTextBox.Clear()
}

# ------------------- Создание формы -------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = "COM Port Monitor (Hex + ASCII) v2"
$form.Size = New-Object System.Drawing.Size(900, 650)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox = $false


# Получаем путь к текущему исполняемому файлу
$exePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName

# Пытаемся извлечь ассоциированную иконку
try {
    $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($exePath)
    if ($icon) {
        $form.Icon = $icon
    }
} catch {
    Write-Host "Не удалось загрузить иконку из $exePath"
}

# Панель настроек
$panel = New-Object System.Windows.Forms.Panel
$panel.Size = New-Object System.Drawing.Size(880, 80)
$panel.Location = New-Object System.Drawing.Point(10, 10)

$labelPort = New-Object System.Windows.Forms.Label
$labelPort.Text = "Port:"; $labelPort.Location = New-Object System.Drawing.Point(10, 15); $labelPort.AutoSize = $true
$panel.Controls.Add($labelPort)

$comboPort = New-Object System.Windows.Forms.ComboBox
$comboPort.Location = New-Object System.Drawing.Point(50, 10)
$comboPort.Size = New-Object System.Drawing.Size(80, 20)
# Заполняем доступные порты
[System.IO.Ports.SerialPort]::GetPortNames() | ForEach-Object { [void]$comboPort.Items.Add($_) }
if ($comboPort.Items.Count -gt 0) { $comboPort.SelectedIndex = 0 }
$panel.Controls.Add($comboPort)

$labelBaud = New-Object System.Windows.Forms.Label
$labelBaud.Text = "Baud:"; $labelBaud.Location = New-Object System.Drawing.Point(150, 15); $labelBaud.AutoSize = $true
$panel.Controls.Add($labelBaud)

$comboBaud = New-Object System.Windows.Forms.ComboBox
$comboBaud.Location = New-Object System.Drawing.Point(190, 10)
$comboBaud.Size = New-Object System.Drawing.Size(80, 20)
@(300, 1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200) | ForEach-Object { [void]$comboBaud.Items.Add($_) }
$comboBaud.SelectedItem = 9600
$panel.Controls.Add($comboBaud)

$labelData = New-Object System.Windows.Forms.Label
$labelData.Text = "Data:"; $labelData.Location = New-Object System.Drawing.Point(290, 15); $labelData.AutoSize = $true
$panel.Controls.Add($labelData)

$comboData = New-Object System.Windows.Forms.ComboBox
$comboData.Location = New-Object System.Drawing.Point(330, 10)
$comboData.Size = New-Object System.Drawing.Size(50, 20)
@(5,6,7,8) | ForEach-Object { [void]$comboData.Items.Add($_) }
$comboData.SelectedItem = 8
$panel.Controls.Add($comboData)

$labelParity = New-Object System.Windows.Forms.Label
$labelParity.Text = "Parity:"; $labelParity.Location = New-Object System.Drawing.Point(400, 15); $labelParity.AutoSize = $true
$panel.Controls.Add($labelParity)

$comboParity = New-Object System.Windows.Forms.ComboBox
$comboParity.Location = New-Object System.Drawing.Point(450, 10)
$comboParity.Size = New-Object System.Drawing.Size(70, 20)
@("None","Odd","Even","Mark","Space") | ForEach-Object { [void]$comboParity.Items.Add($_) }
$comboParity.SelectedItem = "None"
$panel.Controls.Add($comboParity)

$labelStop = New-Object System.Windows.Forms.Label
$labelStop.Text = "Stop:"; $labelStop.Location = New-Object System.Drawing.Point(540, 15); $labelStop.AutoSize = $true
$panel.Controls.Add($labelStop)

$comboStop = New-Object System.Windows.Forms.ComboBox
$comboStop.Location = New-Object System.Drawing.Point(580, 10)
$comboStop.Size = New-Object System.Drawing.Size(70, 20)
@("One","Two","OnePointFive") | ForEach-Object { [void]$comboStop.Items.Add($_) }
$comboStop.SelectedItem = "One"
$panel.Controls.Add($comboStop)

# Кнопки
$btnConnect = New-Object System.Windows.Forms.Button
$btnConnect.Text = "Connect"
$btnConnect.Location = New-Object System.Drawing.Point(670, 8)
$btnConnect.Size = New-Object System.Drawing.Size(80, 25)
$btnConnect.Add_Click({ Connect-Port })
$panel.Controls.Add($btnConnect)

$btnDisconnect = New-Object System.Windows.Forms.Button
$btnDisconnect.Text = "Disconnect"
$btnDisconnect.Location = New-Object System.Drawing.Point(760, 8)
$btnDisconnect.Size = New-Object System.Drawing.Size(80, 25)
$btnDisconnect.Enabled = $false
$btnDisconnect.Add_Click({ Disconnect-Port })
$panel.Controls.Add($btnDisconnect)

$btnClear = New-Object System.Windows.Forms.Button
$btnClear.Text = "Clear"
$btnClear.Location = New-Object System.Drawing.Point(760, 40)
$btnClear.Size = New-Object System.Drawing.Size(80, 25)
$btnClear.Add_Click({ Clear-Output })
$panel.Controls.Add($btnClear)

# Статусная строка
$status = New-Object System.Windows.Forms.Label
$status.Text = "Disconnected"
$status.Location = New-Object System.Drawing.Point(10, 55)
$status.AutoSize = $true
$status.ForeColor = 'Black'
$panel.Controls.Add($status)

$form.Controls.Add($panel)

# RichTextBox для вывода
$script:richTextBox = New-Object System.Windows.Forms.RichTextBox
$script:richTextBox.Location = New-Object System.Drawing.Point(10, 100)
$script:richTextBox.Size = New-Object System.Drawing.Size(870, 500)
$script:richTextBox.Font = New-Object System.Drawing.Font("Consolas", 10)
$script:richTextBox.WordWrap = $false
$script:richTextBox.ReadOnly = $true
$script:richTextBox.BackColor = 'LightGray'
$form.Controls.Add($script:richTextBox)

# ------------------- Закрытие формы -------------------
$form.Add_FormClosing({
    if ($script:timer) { $script:timer.Stop(); $script:timer.Dispose(); $script:timer = $null }
    if ($script:serialPort) {
        if ($script:serialPort.IsOpen) { $script:serialPort.Close() }
        $script:serialPort.Dispose()
        $script:serialPort = $null
    }
})

# Запуск
$form.ShowDialog() | Out-Null

