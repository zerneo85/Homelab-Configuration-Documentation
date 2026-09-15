Option Explicit

' Import this module into the corrected workbook after saving it as .xlsm.
' It incrementally updates "suspicious" from:
'   1) Export            -> confirmed block events
'   2) Fail2BanEvents    -> historical Fail2Ban Ban events
'   3) Fail2Ban          -> CURRENT snapshot only (active state, does NOT increment block count)
'
' _ProcessedEvents prevents the same event from being counted twice.

Public Sub UpdateSuspiciousBlocklist()
    Const SH_SUSP As String = "suspicious"
    Const SH_EXPORT As String = "Export"
    Const SH_F2B As String = "Fail2Ban"
    Const SH_F2B_EVENTS As String = "Fail2BanEvents"
    Const SH_LOG As String = "_ProcessedEvents"

    Dim wb As Workbook: Set wb = ThisWorkbook
    Dim wsS As Worksheet, wsE As Worksheet, wsF As Worksheet, wsFE As Worksheet, wsL As Worksheet

    Set wsS = GetSheet(wb, SH_SUSP, True)
    Set wsE = GetSheet(wb, SH_EXPORT, False)
    Set wsF = GetSheet(wb, SH_F2B, False)
    Set wsFE = GetSheet(wb, SH_F2B_EVENTS, False)
    Set wsL = GetSheet(wb, SH_LOG, True)

    EnsureSuspiciousHeaders wsS
    EnsureLogHeaders wsL

    Dim ipRows As Object: Set ipRows = CreateObject("Scripting.Dictionary")
    ipRows.CompareMode = vbTextCompare

    Dim processed As Object: Set processed = CreateObject("Scripting.Dictionary")
    processed.CompareMode = vbTextCompare

    LoadExistingIPs wsS, ipRows
    LoadProcessed wsL, processed

    Dim addedExport As Long, addedF2BEvents As Long
    If Not wsE Is Nothing Then addedExport = ProcessExport(wsE, wsS, wsL, ipRows, processed)
    If Not wsFE Is Nothing Then addedF2BEvents = ProcessFail2BanEvents(wsFE, wsS, wsL, ipRows, processed)

    ' A snapshot tells us what is active NOW. It is not a historical Ban event,
    ' therefore it must not increase "Aantal keer geblokkeerd".
    ResetFail2BanState wsS
    If Not wsF Is Nothing Then ApplyFail2BanSnapshot wsF, wsS, ipRows

    FormatSuspicious wsS

    On Error Resume Next
    wsL.Visible = xlSheetVeryHidden
    On Error GoTo 0

    MsgBox "Bijwerken gereed." & vbCrLf & _
           "Nieuwe Export-events: " & addedExport & vbCrLf & _
           "Nieuwe Fail2Ban-events: " & addedF2BEvents & vbCrLf & _
           "Unieke IP's: " & ipRows.Count, vbInformation
End Sub

Private Function ProcessExport(ByVal wsE As Worksheet, ByVal wsS As Worksheet, ByVal wsL As Worksheet, _
                               ByVal ipRows As Object, ByVal processed As Object) As Long
    Dim lastRow As Long
    lastRow = MaxLong(LastUsedRow(wsE, 2), LastUsedRow(wsE, 9)) ' B / I

    Dim r As Long, ip As String, reason As String, key As String
    Dim eventDt As Variant, attempts As Long

    For r = 2 To lastRow
        ip = NormalizeIPv4(CStr(wsE.Cells(r, 2).Value))
        If Len(ip) = 0 Then ip = FindIPv4(CStr(wsE.Cells(r, 9).Value))
        If Len(ip) = 0 Then GoTo NextRow

        eventDt = Empty
        If IsDate(wsE.Cells(r, 7).Value) Then
            eventDt = CDate(wsE.Cells(r, 7).Value)
        ElseIf IsDate(wsE.Cells(r, 3).Value) Then
            eventDt = CDate(wsE.Cells(r, 3).Value)
        End If

        attempts = 0
        If IsNumeric(wsE.Cells(r, 6).Value) Then attempts = CLng(wsE.Cells(r, 6).Value)

        reason = Trim$(CStr(wsE.Cells(r, 4).Value))
        If Len(reason) = 0 Then reason = Trim$(CStr(wsE.Cells(r, 9).Value))

        key = "EXPORT|" & ip & "|" & DateKey(eventDt) & "|" & CStr(attempts) & "|" & reason

        If Not processed.Exists(key) Then
            UpsertEvent wsS, ipRows, ip, eventDt, attempts, "Export", reason
            AddProcessed wsL, processed, key, "Export", ip, eventDt
            ProcessExport = ProcessExport + 1
        End If
NextRow:
    Next r
End Function

Private Function ProcessFail2BanEvents(ByVal wsF As Worksheet, ByVal wsS As Worksheet, ByVal wsL As Worksheet, _
                                       ByVal ipRows As Object, ByVal processed As Object) As Long
    ' Expected columns:
    ' A event_time | B jail | C ip
    Dim lastRow As Long: lastRow = LastUsedRow(wsF, 3)
    Dim r As Long, ip As String, jail As String, key As String, reason As String
    Dim eventDt As Variant

    For r = 2 To lastRow
        ip = NormalizeIPv4(CStr(wsF.Cells(r, 3).Value))
        If Len(ip) = 0 Then GoTo NextRow

        jail = Trim$(CStr(wsF.Cells(r, 2).Value))
        eventDt = Empty
        If IsDate(wsF.Cells(r, 1).Value) Then eventDt = CDate(wsF.Cells(r, 1).Value)

        key = "F2B|" & ip & "|" & jail & "|" & DateKey(eventDt)
        reason = "Fail2Ban Ban" & IIf(Len(jail) > 0, " [" & jail & "]", "")

        If Not processed.Exists(key) Then
            UpsertEvent wsS, ipRows, ip, eventDt, 0, "Fail2Ban event", reason
            AddProcessed wsL, processed, key, "Fail2Ban event", ip, eventDt
            ProcessFail2BanEvents = ProcessFail2BanEvents + 1
        End If
NextRow:
    Next r
End Function

Private Sub ApplyFail2BanSnapshot(ByVal wsF As Worksheet, ByVal wsS As Worksheet, ByVal ipRows As Object)
    ' Expected columns:
    ' A jail | B ip | C snapshot_at
    Dim lastRow As Long: lastRow = LastUsedRow(wsF, 2)
    Dim r As Long, ip As String, jail As String
    Dim snapshotDt As Variant, rowS As Long

    For r = 2 To lastRow
        ip = NormalizeIPv4(CStr(wsF.Cells(r, 2).Value))
        If Len(ip) = 0 Then GoTo NextRow

        jail = Trim$(CStr(wsF.Cells(r, 1).Value))
        snapshotDt = Empty
        If IsDate(wsF.Cells(r, 3).Value) Then snapshotDt = CDate(wsF.Cells(r, 3).Value)

        rowS = EnsureIPRow(wsS, ipRows, ip)
        wsS.Cells(rowS, 7).Value = "Ja"
        wsS.Cells(rowS, 8).Value = AppendUnique(CStr(wsS.Cells(rowS, 8).Value), jail)
        wsS.Cells(rowS, 9).Value = AppendUnique(CStr(wsS.Cells(rowS, 9).Value), "Fail2Ban snapshot")

        If Not IsEmpty(snapshotDt) Then
            If Not IsDate(wsS.Cells(rowS, 6).Value) Or CDate(snapshotDt) > CDate(wsS.Cells(rowS, 6).Value) Then
                wsS.Cells(rowS, 6).Value = CDate(snapshotDt)
            End If
        End If
NextRow:
    Next r
End Sub

Private Sub UpsertEvent(ByVal wsS As Worksheet, ByVal ipRows As Object, ByVal ip As String, _
                        ByVal eventDt As Variant, ByVal attempts As Long, _
                        ByVal source As String, ByVal reason As String)
    Dim rowS As Long: rowS = EnsureIPRow(wsS, ipRows, ip)

    wsS.Cells(rowS, 2).Value = NzLong(wsS.Cells(rowS, 2).Value) + 1
    wsS.Cells(rowS, 3).Value = NzLong(wsS.Cells(rowS, 3).Value) + attempts
    wsS.Cells(rowS, 9).Value = AppendUnique(CStr(wsS.Cells(rowS, 9).Value), source)

    If Not IsEmpty(eventDt) Then
        If Not IsDate(wsS.Cells(rowS, 4).Value) Or CDate(eventDt) < CDate(wsS.Cells(rowS, 4).Value) Then
            wsS.Cells(rowS, 4).Value = CDate(eventDt)
        End If

        If Not IsDate(wsS.Cells(rowS, 5).Value) Or CDate(eventDt) >= CDate(wsS.Cells(rowS, 5).Value) Then
            wsS.Cells(rowS, 5).Value = CDate(eventDt)
            If Len(reason) > 0 Then wsS.Cells(rowS, 10).Value = reason
        End If

        If Not IsDate(wsS.Cells(rowS, 6).Value) Or CDate(eventDt) > CDate(wsS.Cells(rowS, 6).Value) Then
            wsS.Cells(rowS, 6).Value = CDate(eventDt)
        End If
    ElseIf Len(CStr(wsS.Cells(rowS, 10).Value)) = 0 And Len(reason) > 0 Then
        wsS.Cells(rowS, 10).Value = reason
    End If
End Sub

Private Function EnsureIPRow(ByVal wsS As Worksheet, ByVal ipRows As Object, ByVal ip As String) As Long
    If ipRows.Exists(ip) Then
        EnsureIPRow = CLng(ipRows(ip))
        Exit Function
    End If

    Dim rowS As Long: rowS = LastUsedRow(wsS, 1) + 1
    If rowS < 2 Then rowS = 2

    wsS.Cells(rowS, 1).Value = ip
    wsS.Cells(rowS, 2).Value = 0
    wsS.Cells(rowS, 3).Value = 0
    wsS.Cells(rowS, 7).Value = "Nee"

    ipRows.Add ip, rowS
    EnsureIPRow = rowS
End Function

Private Sub LoadExistingIPs(ByVal wsS As Worksheet, ByVal ipRows As Object)
    Dim lastRow As Long: lastRow = LastUsedRow(wsS, 1)
    Dim r As Long, ip As String

    For r = 2 To lastRow
        ip = NormalizeIPv4(CStr(wsS.Cells(r, 1).Value))
        If Len(ip) > 0 Then
            If Not ipRows.Exists(ip) Then ipRows.Add ip, r
        End If
    Next r
End Sub

Private Sub LoadProcessed(ByVal wsL As Worksheet, ByVal processed As Object)
    Dim lastRow As Long: lastRow = LastUsedRow(wsL, 1)
    Dim r As Long, key As String

    For r = 2 To lastRow
        key = CStr(wsL.Cells(r, 1).Value)
        If Len(key) > 0 Then
            If Not processed.Exists(key) Then processed.Add key, True
        End If
    Next r
End Sub

Private Sub AddProcessed(ByVal wsL As Worksheet, ByVal processed As Object, ByVal key As String, _
                         ByVal source As String, ByVal ip As String, ByVal eventDt As Variant)
    Dim r As Long: r = LastUsedRow(wsL, 1) + 1
    If r < 2 Then r = 2

    wsL.Cells(r, 1).Value = key
    wsL.Cells(r, 2).Value = source
    wsL.Cells(r, 3).Value = ip
    If Not IsEmpty(eventDt) Then wsL.Cells(r, 4).Value = CDate(eventDt)

    processed.Add key, True
End Sub

Private Sub ResetFail2BanState(ByVal wsS As Worksheet)
    Dim lastRow As Long: lastRow = LastUsedRow(wsS, 1)
    If lastRow < 2 Then Exit Sub
    wsS.Range("G2:G" & lastRow).Value = "Nee"
    wsS.Range("H2:H" & lastRow).ClearContents
End Sub

Private Sub EnsureSuspiciousHeaders(ByVal ws As Worksheet)
    Dim headers As Variant
    headers = Array("IP-adres", "Aantal keer geblokkeerd", "Totaal inlogpogingen", _
                    "Eerste blokkering", "Laatste blokkering", "Updated on", _
                    "Fail2Ban actief", "Jail(s)", "Bron", "Laatste reden")
    ws.Range("A1:J1").Value = headers
End Sub

Private Sub EnsureLogHeaders(ByVal ws As Worksheet)
    ws.Range("A1:D1").Value = Array("EventKey", "Source", "IP", "EventTime")
End Sub

Private Sub FormatSuspicious(ByVal ws As Worksheet)
    With ws
        .Range("A1:J1").Font.Bold = True
        .Range("A1:J1").Interior.Color = RGB(47, 117, 181)
        .Range("A1:J1").Font.Color = RGB(255, 255, 255)

        .Columns("A").ColumnWidth = 18
        .Columns("B:C").ColumnWidth = 20
        .Columns("D:F").ColumnWidth = 19
        .Columns("G").ColumnWidth = 16
        .Columns("H:I").ColumnWidth = 28
        .Columns("J").ColumnWidth = 55

        .Columns("D:F").NumberFormat = "yyyy-mm-dd hh:mm"
        .Columns("J").WrapText = True

        .Activate
        ActiveWindow.FreezePanes = False
        .Range("A2").Select
        ActiveWindow.FreezePanes = True
    End With
End Sub

Private Function GetSheet(ByVal wb As Workbook, ByVal sheetName As String, ByVal createIfMissing As Boolean) As Worksheet
    On Error Resume Next
    Set GetSheet = wb.Worksheets(sheetName)
    On Error GoTo 0

    If GetSheet Is Nothing And createIfMissing Then
        Set GetSheet = wb.Worksheets.Add(After:=wb.Worksheets(wb.Worksheets.Count))
        GetSheet.Name = sheetName
    End If
End Function

Private Function NormalizeIPv4(ByVal s As String) As String
    s = Trim$(s)
    If IsValidIPv4(s) Then NormalizeIPv4 = s
End Function

Private Function FindIPv4(ByVal s As String) As String
    Dim re As Object: Set re = CreateObject("VBScript.RegExp")
    re.Pattern = "(^|[^0-9])(\d{1,3}(?:\.\d{1,3}){3})([^0-9]|$)"
    re.Global = True

    Dim ms As Object, m As Object, candidate As String
    If re.Test(s) Then
        Set ms = re.Execute(s)
        For Each m In ms
            candidate = CStr(m.SubMatches(1))
            If IsValidIPv4(candidate) Then
                FindIPv4 = candidate
                Exit Function
            End If
        Next m
    End If
End Function

Private Function IsValidIPv4(ByVal s As String) As Boolean
    Dim p() As String, i As Long, n As Long
    s = Trim$(s)
    p = Split(s, ".")
    If UBound(p) <> 3 Then Exit Function

    For i = 0 To 3
        If Len(p(i)) = 0 Or Not IsNumeric(p(i)) Then Exit Function
        n = CLng(p(i))
        If n < 0 Or n > 255 Then Exit Function
        If CStr(n) <> p(i) And Not (p(i) = "0") Then
            ' Reject ambiguous values such as 001.
            Exit Function
        End If
    Next i
    IsValidIPv4 = True
End Function

Private Function AppendUnique(ByVal currentValue As String, ByVal newValue As String) As String
    currentValue = Trim$(currentValue)
    newValue = Trim$(newValue)

    If Len(newValue) = 0 Then
        AppendUnique = currentValue
        Exit Function
    End If

    If Len(currentValue) = 0 Then
        AppendUnique = newValue
        Exit Function
    End If

    Dim part As Variant
    For Each part In Split(currentValue, ",")
        If StrComp(Trim$(CStr(part)), newValue, vbTextCompare) = 0 Then
            AppendUnique = currentValue
            Exit Function
        End If
    Next part

    AppendUnique = currentValue & ", " & newValue
End Function

Private Function DateKey(ByVal v As Variant) As String
    If IsEmpty(v) Or Not IsDate(v) Then
        DateKey = ""
    Else
        DateKey = Format$(CDate(v), "yyyy-mm-dd hh:nn:ss")
    End If
End Function

Private Function NzLong(ByVal v As Variant) As Long
    If IsNumeric(v) Then NzLong = CLng(v) Else NzLong = 0
End Function

Private Function LastUsedRow(ByVal ws As Worksheet, ByVal col As Long) As Long
    LastUsedRow = ws.Cells(ws.Rows.Count, col).End(xlUp).Row
End Function

Private Function MaxLong(ByVal a As Long, ByVal b As Long) As Long
    If a > b Then MaxLong = a Else MaxLong = b
End Function
