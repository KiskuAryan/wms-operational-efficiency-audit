' ==============================================================================
' Legacy Warehouse Management System (WMS) - Data Access Module
' Target System: Enterprise 3PL Legacy WMS Architecture (circa 2014-2020)
' File: legacy_wms_data_access.vb
'
' AUDIT CONTEXT:
' This module handles order retrieval, bin allocation, and status updates.
' During peak operational hours (10:00 - 14:00), this component experiences
' severe lock contention, thread starvation, and query latency exceeding 4.2 seconds.
' ==============================================================================

Imports System
Imports System.Data
Imports System.Data.SqlClient
Imports System.Collections.Generic

Namespace LegacyWMS.DataAccess

    Public Class OrderFulfillmentManager

        Private ReadOnly connectionString As String = "Server=wms-sql-srv01;Database=Enterprise_WMS;Integrated Security=True;"

        ''' <summary>
        ''' ANTI-PATTERN 1: N+1 Database Roundtrip Problem
        ''' Fetches pending orders and then executes a separate query inside a loop
        ''' for each order line item, generating thousands of unnecessary TCP roundtrips.
        ''' </summary>
        Public Function GetPendingOrdersWithItemsLegacy() As DataTable
            Dim ordersTable As New DataTable()

            Using conn As New SqlConnection(connectionString)
                conn.Open()

                ' Issue 1A: SELECT * loads unused columns; lacks (NOLOCK) or SNAPSHOT isolation
                ' Leads to shared table locks on high-velocity transactional tables.
                Dim orderSql As String = "SELECT * FROM orders WHERE status = 'PENDING' ORDER BY order_timestamp ASC"
                
                Using cmd As New SqlCommand(orderSql, conn)
                    Using adapter As New SqlDataAdapter(cmd)
                        adapter.Fill(ordersTable)
                    End Using
                End Using

                ' Issue 1B: Sequential loop generating N queries for N orders
                For Each row As DataRow In ordersTable.Rows
                    Dim orderId As Integer = Convert.ToInt32(row("order_id"))

                    ' String concatenation risk + separate roundtrip per order
                    Dim itemsSql As String = "SELECT * FROM order_items WHERE order_id = " & orderId.ToString()
                    Using itemCmd As New SqlCommand(itemsSql, conn)
                        Using itemAdapter As New SqlDataAdapter(itemCmd)
                            Dim itemsTable As New DataTable()
                            itemAdapter.Fill(itemsTable)
                            ' Attaching items to local memory object...
                        End Using
                    End Using
                Next
            End Using

            Return ordersTable
        End Function


        ''' <summary>
        ''' ANTI-PATTERN 2: High Contention Bin Allocation with Manual Table Locks
        ''' Uses explicit table locks across the entire inventory table during allocation
        ''' instead of row-level optimistic concurrency, causing worker terminal freezes.
        ''' </summary>
        Public Sub AllocateOrderBinsLegacy(ByVal orderId As Integer)
            Using conn As New SqlConnection(connectionString)
                conn.Open()
                Dim tx As SqlTransaction = conn.BeginTransaction(IsolationLevel.Serializable)

                Try
                    ' Issue 2A: Serializable table scan locks out warehouse pickers scanning barcodes
                    Dim allocSql As String = _
                        "UPDATE inventory_bins WITH (TABLOCKX) " & _
                        "SET current_qty = current_qty - oi.requested_qty " & _
                        "FROM inventory_bins b " & _
                        "INNER JOIN order_items oi ON b.current_sku_id = oi.sku_id " & _
                        "WHERE oi.order_id = @OrderId"

                    Using cmd As New SqlCommand(allocSql, conn, tx)
                        cmd.Parameters.AddWithValue("@OrderId", orderId)
                        cmd.ExecuteNonQuery()
                    End Using

                    ' Issue 2B: Unindexed status update
                    Dim updateOrderSql As String = _
                        "UPDATE orders SET status = 'ALLOCATED' WHERE order_id = @OrderId"

                    Using cmdOrder As New SqlCommand(updateOrderSql, conn, tx)
                        cmdOrder.Parameters.AddWithValue("@OrderId", orderId)
                        cmdOrder.ExecuteNonQuery()
                    End Using

                    tx.Commit()
                Catch ex As Exception
                    tx.Rollback()
                    Throw New ApplicationException("Legacy allocation failed due to lock contention.", ex)
                End Try
            End Using
        End Sub

    End Class

End Namespace
