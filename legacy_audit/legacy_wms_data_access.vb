' ==============================================================================
' Legacy Warehouse Management System (WMS) - Data Access Module
' Status: Illustrative Architectural Study & Conceptual Refactor Sketch
' Author: Aryan Chintaman Manjhi (github.com/KiskuAryan)
'
' DISCLAIMER:
' This file contains conceptual ADO.NET code sketches illustrating legacy
' anti-patterns alongside proposed modern patterns. It is intended for architectural
' analysis and review, not as a standalone compiled production binary.
' ==============================================================================

Imports System
Imports System.Data
Imports System.Data.SqlClient
Imports System.Threading.Tasks
Imports System.Collections.Generic

Namespace ConceptualWMS.DataAccess

    ''' <summary>
    ''' PART 1: LEGACY IMPLEMENTATION SKETCH (Identified Anti-Patterns)
    ''' Models the typical single-threaded ADO.NET patterns from legacy WMS backends.
    ''' </summary>
    Public Class LegacyOrderFulfillmentManager

        Private ReadOnly connectionString As String = "Server=wms-sql-srv01;Database=Enterprise_WMS;Integrated Security=True;"

        ''' <summary>
        ''' ANTI-PATTERN 1: The N+1 Network Roundtrip Problem
        ''' Issues 1 parent query followed by N sequential child queries inside a loop.
        ''' </summary>
        Public Function GetPendingOrdersLegacy() As DataTable
            Dim ordersTable As New DataTable()

            Using conn As New SqlConnection(connectionString)
                conn.Open()

                Dim orderSql As String = "SELECT * FROM orders WHERE status = 'PENDING' ORDER BY order_timestamp ASC"
                Using cmd As New SqlCommand(orderSql, conn)
                    Using adapter As New SqlDataAdapter(cmd)
                        adapter.Fill(ordersTable)
                    End Using
                End Using

                ' N+1 roundtrips across local network
                For Each row As DataRow In ordersTable.Rows
                    Dim orderId As Integer = Convert.ToInt32(row("order_id"))
                    Dim itemsSql As String = "SELECT * FROM order_items WHERE order_id = " & orderId.ToString()
                    Using itemCmd As New SqlCommand(itemsSql, conn)
                        Using itemAdapter As New SqlDataAdapter(itemCmd)
                            Dim itemsTable As New DataTable()
                            itemAdapter.Fill(itemsTable)
                        End Using
                    End Using
                Next
            End Using

            Return ordersTable
        End Function


        ''' <summary>
        ''' ANTI-PATTERN 2: Coarse-Grained Table Locking
        ''' Uses TABLOCKX which locks out concurrent barcode scan terminals across the warehouse.
        ''' </summary>
        Public Sub AllocateOrderBinsLegacy(ByVal orderId As Integer)
            Using conn As New SqlConnection(connectionString)
                conn.Open()
                Dim tx As SqlTransaction = conn.BeginTransaction(IsolationLevel.Serializable)

                Try
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

                    Dim updateOrderSql As String = _
                        "UPDATE orders SET status = 'ALLOCATED' WHERE order_id = @OrderId"
                    Using cmdOrder As New SqlCommand(updateOrderSql, conn, tx)
                        cmdOrder.Parameters.AddWithValue("@OrderId", orderId)
                        cmdOrder.ExecuteNonQuery()
                    End Using

                    tx.Commit()
                Catch ex As Exception
                    tx.Rollback()
                    Throw
                End Try
            End Using
        End Sub

    End Class


    ''' <summary>
    ''' PART 2: PROPOSED MODERN ARCHITECTURAL SKETCH
    ''' Demonstrates consistent batch selection, full-order atomicity, and non-blocking async I/O.
    ''' </summary>
    Public Class ProposedOptimizedFulfillmentService

        Private ReadOnly _connectionString As String

        Public Sub New(connectionString As String)
            _connectionString = connectionString
        End Sub

        ''' <summary>
        ''' PROPOSED FIX 1: Consistent Single-Roundtrip Batching
        ''' Uses a table variable snapshot to guarantee consistent parent-child batch retrieval
        ''' in a single database roundtrip without race conditions.
        ''' </summary>
        Public Async Function GetPendingOrdersBatchAsync(batchSize As Integer) As Task(Of DataSet)
            Dim ds As New DataSet("WmsPendingBatch")

            Const batchSql As String = 
                "SET NOCOUNT ON; " &
                "DECLARE @TargetOrders TABLE (order_id INT PRIMARY KEY); " &
                " " &
                "INSERT INTO @TargetOrders (order_id) " &
                "SELECT TOP (@BatchSize) order_id " &
                "FROM orders WITH (READCOMMITTEDLOCK) " &
                "WHERE status = 'PENDING' " &
                "ORDER BY CASE priority_level WHEN 'SAME_DAY' THEN 1 WHEN 'EXPRESS' THEN 2 ELSE 3 END, " &
                "         order_timestamp ASC; " &
                " " &
                "SELECT o.order_id, o.order_number, o.priority_level, o.order_timestamp " &
                "FROM orders o INNER JOIN @TargetOrders t ON o.order_id = t.order_id; " &
                " " &
                "SELECT oi.item_id, oi.order_id, oi.sku_id, oi.requested_qty, b.bin_id, b.bin_code " &
                "FROM order_items oi " &
                "INNER JOIN @TargetOrders t ON oi.order_id = t.order_id " &
                "INNER JOIN inventory_bins b ON oi.allocated_bin_id = b.bin_id;"

            Using conn As New SqlConnection(_connectionString)
                Using cmd As New SqlCommand(batchSql, conn)
                    cmd.Parameters.Add(New SqlParameter("@BatchSize", SqlDbType.Int) With {.Value = batchSize})
                    
                    Await conn.OpenAsync()
                    Using adapter As New SqlDataAdapter(cmd)
                        adapter.TableMappings.Add("Table", "Orders")
                        adapter.TableMappings.Add("Table1", "OrderItems")
                        adapter.Fill(ds)
                    End Using
                End Using
            End Using

            Return ds
        End Function


        ''' <summary>
        ''' PROPOSED FIX 2: Full-Order All-or-Nothing Atomicity with Row-Level Concurrency
        ''' Ensures partial allocations are rejected: an order is either 100% allocated or rolled back.
        ''' Uses ROWLOCK to eliminate whole-table freezing on worker RF scanners.
        ''' </summary>
        Public Async Function TryAllocateOrderAtomicAsync(orderId As Integer) As Task(Of Boolean)
            ' Atomic verification and decrement script:
            ' Step 1: Count line items that have sufficient stock.
            ' Step 2: If available items match total order items, perform row-level update and commit.
            ' Step 3: Otherwise, roll back immediately (prevents orphaned half-allocated orders).
            Const atomicSql As String =
                "BEGIN TRANSACTION; " &
                " " &
                "DECLARE @TotalLines INT, @AvailableLines INT; " &
                " " &
                "SELECT @TotalLines = COUNT(*) FROM order_items WHERE order_id = @OrderId; " &
                " " &
                "SELECT @AvailableLines = COUNT(*) " &
                "FROM order_items oi " &
                "INNER JOIN inventory_bins b WITH (UPDLOCK, ROWLOCK) ON oi.allocated_bin_id = b.bin_id " &
                "WHERE oi.order_id = @OrderId AND b.current_qty >= oi.requested_qty; " &
                " " &
                "IF @TotalLines = @AvailableLines AND @TotalLines > 0 " &
                "BEGIN " &
                "    UPDATE b WITH (ROWLOCK) " &
                "    SET b.current_qty = b.current_qty - oi.requested_qty " &
                "    FROM inventory_bins b " &
                "    INNER JOIN order_items oi ON b.bin_id = oi.allocated_bin_id " &
                "    WHERE oi.order_id = @OrderId; " &
                " " &
                "    UPDATE orders SET status = 'ALLOCATED' WHERE order_id = @OrderId; " &
                "    COMMIT TRANSACTION; " &
                "    SELECT 1 AS AllocationSuccess; " &
                "END " &
                "ELSE " &
                "BEGIN " &
                "    ROLLBACK TRANSACTION; " &
                "    SELECT 0 AS AllocationSuccess; " &
                "END;"

            Using conn As New SqlConnection(_connectionString)
                Using cmd As New SqlCommand(atomicSql, conn)
                    cmd.Parameters.Add(New SqlParameter("@OrderId", SqlDbType.Int) With {.Value = orderId})
                    Await conn.OpenAsync()
                    Dim result As Object = Await cmd.ExecuteScalarAsync()
                    Return Convert.ToInt32(result) = 1
                End Using
            End Using
        End Function

    End Class

End Namespace
